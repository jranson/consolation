//
//  LibavMPEG2.c
//  PlaybackKit
//
//  The only file that includes FFmpeg headers. libavcodec and libavutil are LGPL-2.1 and linked dynamically as
//  embedded frameworks. This file is Apache-2.0 and copies no FFmpeg code.
//

#include "LibavMPEG2.h"
#include "LibavMPEG2Pool.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/frame.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>

struct LibavMPEG2Decoder {
    AVCodecContext *context;
    AVPacket *packet;
    AVFrame *frame;
    LibavMPEG2Pool *pool;
    int holdsFrame;
};

LibavMPEG2Decoder *libav_mpeg2_open(int32_t threadCount) {
    // libavcodec logs to stderr by default, including a line for every damaged macroblock it conceals (weak signal
    // does that many times a second). The app reports decoder failures itself, so keep libavcodec quiet.
    av_log_set_level(AV_LOG_QUIET);
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_MPEG2VIDEO);
    if (codec == NULL) return NULL;
    LibavMPEG2Decoder *decoder = calloc(1, sizeof(LibavMPEG2Decoder));
    if (decoder == NULL) return NULL;
    decoder->context = avcodec_alloc_context3(codec);
    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    decoder->pool = libav_mpeg2_pool_create();
    if (decoder->context == NULL || decoder->packet == NULL || decoder->frame == NULL || decoder->pool == NULL) {
        libav_mpeg2_close(decoder);
        return NULL;
    }
    decoder->context->thread_count = threadCount > 0 ? threadCount : 1;
    decoder->context->thread_type = FF_THREAD_SLICE;
    decoder->context->pkt_timebase = (AVRational){ 1, 90000 };
    // Decode into our page-aligned pool (the MPEG-2 decoder supports direct rendering, AV_CODEC_CAP_DR1).
    if (codec->capabilities & AV_CODEC_CAP_DR1) {
        decoder->context->opaque = decoder->pool;
        decoder->context->get_buffer2 = libav_mpeg2_pool_get_buffer;
    }
    if (avcodec_open2(decoder->context, codec, NULL) < 0) {
        libav_mpeg2_close(decoder);
        return NULL;
    }
    return decoder;
}

void libav_mpeg2_close(LibavMPEG2Decoder *decoder) {
    if (decoder == NULL) return;
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->packet);
    avcodec_free_context(&decoder->context);
    libav_mpeg2_pool_destroy(decoder->pool);
    free(decoder);
}

static LibavMPEG2Result libav_mpeg2_result(int status) {
    if (status >= 0) return LibavMPEG2ResultSuccess;
    if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) return LibavMPEG2ResultNeedMore;
    if (status == AVERROR_INVALIDDATA) return LibavMPEG2ResultBadData;
    return LibavMPEG2ResultFailed;
}

LibavMPEG2Result libav_mpeg2_send(LibavMPEG2Decoder *decoder, const uint8_t *data, size_t size, int64_t pts) {
    if (size == 0 || size > INT32_MAX) return LibavMPEG2ResultBadData;
    av_packet_unref(decoder->packet);
    // Not reference-counted, so avcodec_send_packet copies it into a padded buffer.
    decoder->packet->data = (uint8_t *)data;
    decoder->packet->size = (int)size;
    decoder->packet->pts = pts == INT64_MIN ? AV_NOPTS_VALUE : pts;
    decoder->packet->dts = AV_NOPTS_VALUE;
    int status = avcodec_send_packet(decoder->context, decoder->packet);
    decoder->packet->data = NULL;
    decoder->packet->size = 0;
    return libav_mpeg2_result(status);
}

_Static_assert(LIBAV_MPEG2_INPUT_PADDING == AV_INPUT_BUFFER_PADDING_SIZE, "input padding differs from libavcodec's");

/// Releases owners of data sent with `libav_mpeg2_send_owned` (`libav_mpeg2_set_owner_release`).
static _Atomic(LibavMPEG2Release) libav_mpeg2_owner_release = NULL;

void libav_mpeg2_set_owner_release(LibavMPEG2Release release) {
    atomic_store_explicit(&libav_mpeg2_owner_release, release, memory_order_release);
}

static void libav_mpeg2_owner_free(void *owner, uint8_t *data) {
    (void)data;
    atomic_load_explicit(&libav_mpeg2_owner_release, memory_order_acquire)(owner);
}

LibavMPEG2Result libav_mpeg2_send_owned(LibavMPEG2Decoder *decoder, const uint8_t *data, size_t size, int64_t pts,
                                        void *owner) {
    LibavMPEG2Release release = atomic_load_explicit(&libav_mpeg2_owner_release, memory_order_acquire);
    if (release == NULL) return LibavMPEG2ResultFailed;
    if (size == 0 || size > INT32_MAX - AV_INPUT_BUFFER_PADDING_SIZE) {
        release(owner);
        return LibavMPEG2ResultBadData;
    }
    av_packet_unref(decoder->packet);
    // Reference-counted and padded, so avcodec_send_packet takes a reference instead of copying. The buffer covers
    // the padding too; libavcodec only reads it. The owner is the buffer's opaque value, so nothing else is allocated
    // for it.
    decoder->packet->buf = av_buffer_create((uint8_t *)data, size + AV_INPUT_BUFFER_PADDING_SIZE,
                                            libav_mpeg2_owner_free, owner, AV_BUFFER_FLAG_READONLY);
    if (decoder->packet->buf == NULL) {
        release(owner);
        return LibavMPEG2ResultFailed;
    }
    decoder->packet->data = (uint8_t *)data;
    decoder->packet->size = (int)size;
    decoder->packet->pts = pts == INT64_MIN ? AV_NOPTS_VALUE : pts;
    decoder->packet->dts = AV_NOPTS_VALUE;
    int status = avcodec_send_packet(decoder->context, decoder->packet);
    // Drops this packet's reference; the owner is released now if libavcodec kept none (for example when sending
    // failed).
    av_packet_unref(decoder->packet);
    return libav_mpeg2_result(status);
}

LibavMPEG2Result libav_mpeg2_send_end(LibavMPEG2Decoder *decoder) {
    return libav_mpeg2_result(avcodec_send_packet(decoder->context, NULL));
}

LibavMPEG2Result libav_mpeg2_receive(LibavMPEG2Decoder *decoder, LibavMPEG2Picture *picture) {
    av_frame_unref(decoder->frame);
    decoder->holdsFrame = 0;
    int status = avcodec_receive_frame(decoder->context, decoder->frame);
    if (status < 0) return libav_mpeg2_result(status);
    decoder->holdsFrame = 1;
    const AVFrame *frame = decoder->frame;
    int64_t pts = frame->pts != AV_NOPTS_VALUE ? frame->pts : frame->best_effort_timestamp;
    memset(picture, 0, sizeof(*picture));
    picture->width = frame->width;
    picture->height = frame->height;
    picture->pts = pts == AV_NOPTS_VALUE ? INT64_MIN : pts;
    picture->interlaced = (frame->flags & AV_FRAME_FLAG_INTERLACED) != 0;
    picture->topFieldFirst = (frame->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0;
    picture->colorPrimaries = frame->color_primaries;
    picture->transferCharacteristics = frame->color_trc;
    picture->matrixCoefficients = frame->colorspace;
    return LibavMPEG2ResultSuccess;
}

LibavMPEG2Result libav_mpeg2_copy_nv12(LibavMPEG2Decoder *decoder, uint8_t *luma, size_t lumaStride,
                                       uint8_t *chroma, size_t chromaStride) {
    if (!decoder->holdsFrame) return LibavMPEG2ResultFailed;
    const AVFrame *frame = decoder->frame;
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(frame->format);
    if (descriptor == NULL || descriptor->nb_components != 3 || (descriptor->flags & AV_PIX_FMT_FLAG_PLANAR) == 0
        || descriptor->comp[0].depth != 8 || descriptor->log2_chroma_w != 1 || descriptor->log2_chroma_h > 1) {
        return LibavMPEG2ResultUnsupportedFormat;
    }
    const int width = frame->width;
    const int height = frame->height;
    for (int row = 0; row < height; row++) {
        memcpy(luma + (size_t)row * lumaStride, frame->data[0] + (ptrdiff_t)row * frame->linesize[0], (size_t)width);
    }
    // 4:2:0 reads every chroma row; 4:2:2 (log2_chroma_h 0) reads every other one.
    const int rowStep = descriptor->log2_chroma_h == 1 ? 1 : 2;
    const int chromaWidth = width / 2;
    const int chromaHeight = height / 2;
    for (int row = 0; row < chromaHeight; row++) {
        const uint8_t *blue = frame->data[1] + (ptrdiff_t)(row * rowStep) * frame->linesize[1];
        const uint8_t *red = frame->data[2] + (ptrdiff_t)(row * rowStep) * frame->linesize[2];
        uint8_t *pairs = chroma + (size_t)row * chromaStride;
        for (int column = 0; column < chromaWidth; column++) {
            pairs[2 * column] = blue[column];
            pairs[2 * column + 1] = red[column];
        }
    }
    return LibavMPEG2ResultSuccess;
}

LibavMPEG2Result libav_mpeg2_planes(LibavMPEG2Decoder *decoder, LibavMPEG2Planes *planes) {
    if (!decoder->holdsFrame) return LibavMPEG2ResultFailed;
    return libav_mpeg2_pool_describe(decoder->pool, decoder->frame, planes);
}

const void *libav_mpeg2_picture_retain(LibavMPEG2Decoder *decoder) {
    if (!decoder->holdsFrame) return NULL;
    return av_frame_clone(decoder->frame);
}

void libav_mpeg2_picture_release(const void *picture) {
    // Unreferencing only touches the frame's buffers (atomic counts and the block's own free callback), never the
    // decoder, so this is safe on Metal's completion thread and after the decoder closed.
    AVFrame *frame = (AVFrame *)picture;
    av_frame_free(&frame);
}

void libav_mpeg2_flush(LibavMPEG2Decoder *decoder) {
    av_frame_unref(decoder->frame);
    decoder->holdsFrame = 0;
    avcodec_flush_buffers(decoder->context);
}

uint32_t libav_codec_version(void) { return avcodec_version(); }
const char *libav_ffmpeg_version(void) { return av_version_info(); }
const char *libav_codec_license(void) { return avcodec_license(); }
const char *libav_codec_configuration(void) { return avcodec_configuration(); }
const char *libav_util_license(void) { return avutil_license(); }
const char *libav_util_configuration(void) { return avutil_configuration(); }
