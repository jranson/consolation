//
//  LibavMPEG2.h
//  PlaybackKit
//
//  A thin C wrapper over FFmpeg's libavcodec (LGPL-2.1, dynamically linked) exposing only what PlaybackKit needs to
//  decode MPEG-1/MPEG-2 video: open, send a picture, receive a picture, describe its planes (decoded straight into
//  page-aligned blocks that Metal can wrap without copying) or copy it out as NV12, flush and close, plus the
//  library's version, licence and configuration strings. No FFmpeg types appear here, so a major FFmpeg bump only
//  touches the .c files.
//

#ifndef LIBAV_MPEG2_H
#define LIBAV_MPEG2_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Results from the calls below.
typedef enum __attribute__((enum_extensibility(closed))) LibavMPEG2Result : int32_t {
    LibavMPEG2ResultSuccess = 0,
    /// No picture is ready yet; send more data.
    LibavMPEG2ResultNeedMore = 1,
    /// The input was not decodable (damaged or missing references). Safe to skip and continue.
    LibavMPEG2ResultBadData = -1,
    /// The decoder failed in a way it can't recover from; close it and open a new one.
    LibavMPEG2ResultFailed = -2,
    /// The decoded picture has a chroma layout the NV12 copy doesn't handle.
    LibavMPEG2ResultUnsupportedFormat = -3
} LibavMPEG2Result;

/// Facts about the picture held by the decoder after a successful `libav_mpeg2_receive`.
typedef struct {
    int32_t width;
    int32_t height;
    /// The presentation time passed with the picture's data, or INT64_MIN when it had none.
    int64_t pts;
    int32_t interlaced;
    int32_t topFieldFirst;
    /// ISO/IEC 23091-2 (H.273) code points; 2 means unspecified.
    int32_t colorPrimaries;
    int32_t transferCharacteristics;
    int32_t matrixCoefficients;
} LibavMPEG2Picture;

/// Where the held picture's planes are, after a successful `libav_mpeg2_planes`. All three planes live in one
/// page-aligned block of `length` bytes starting at `base` (`length` is a whole number of pages), so the block can be
/// wrapped as one Metal buffer without copying. Offsets are from `base`.
typedef struct {
    /// The block, for `libav_mpeg2_block_retain` and `libav_mpeg2_block_release`.
    const void *_Nullable block;
    /// Unique per block for the life of the process, so a wrapper made for a block can be reused for it.
    uint64_t serial;
    const uint8_t *_Nullable base;
    size_t length;
    size_t lumaOffset;
    size_t blueOffset;
    size_t redOffset;
    int32_t lumaStride;
    /// Shared by the Cb and Cr planes.
    int32_t chromaStride;
    /// 1 for 4:2:0; 2 for 4:2:2, whose every other chroma row makes 4:2:0.
    int32_t chromaRowStep;
} LibavMPEG2Planes;

typedef struct LibavMPEG2Decoder LibavMPEG2Decoder;

/// Opens an MPEG-2 video decoder (it also decodes MPEG-1). `threadCount` 1 decodes on the calling thread only.
/// Returns NULL on failure.
LibavMPEG2Decoder *_Nullable libav_mpeg2_open(int32_t threadCount);

/// Frees the decoder and any picture it holds. Accepts NULL.
void libav_mpeg2_close(LibavMPEG2Decoder *_Nullable decoder);

/// Sends one coded picture (or any whole number of them). The data is copied; `pts` is returned with the picture.
LibavMPEG2Result libav_mpeg2_send(LibavMPEG2Decoder *_Nonnull decoder, const uint8_t *_Nonnull data, size_t size,
                                  int64_t pts);

/// Zeroed bytes that must follow the data passed to `libav_mpeg2_send_owned` (libavcodec's input padding: its
/// bitstream reader may read that far past the end).
#define LIBAV_MPEG2_INPUT_PADDING 64

/// Releases an owner passed to `libav_mpeg2_send_owned`. Called exactly once per owner, on whichever thread drops the
/// last reference to its data (usually inside a later send, receive, flush or close).
typedef void (*LibavMPEG2Release)(void *_Nullable owner);

/// Sets the function that releases owners passed to `libav_mpeg2_send_owned`, for the whole process: libavcodec's
/// free callback only gets the owner, and the data's last reference isn't tied to any one decoder. Set it before the
/// first owned send; setting the same function again is harmless. Safe from any thread.
void libav_mpeg2_set_owner_release(LibavMPEG2Release _Nonnull release);

/// Sends one coded picture without copying it: libavcodec references `data` until the function set with
/// `libav_mpeg2_set_owner_release` releases `owner`, which may be after this call returns. `data` must stay valid and
/// unchanged until then and must be followed by `LIBAV_MPEG2_INPUT_PADDING` zeroed bytes. `owner` is released exactly
/// once, also when this call fails, except when no release function was set: then it fails without taking `owner`.
LibavMPEG2Result libav_mpeg2_send_owned(LibavMPEG2Decoder *_Nonnull decoder, const uint8_t *_Nonnull data,
                                        size_t size, int64_t pts, void *_Nullable owner);

/// Signals the end of the stream so the last pictures can be received.
LibavMPEG2Result libav_mpeg2_send_end(LibavMPEG2Decoder *_Nonnull decoder);

/// Receives the next decoded picture (display order) and holds it until the next receive or flush.
/// Returns Success with `picture` filled, NeedMore when none is ready, or an error.
LibavMPEG2Result libav_mpeg2_receive(LibavMPEG2Decoder *_Nonnull decoder, LibavMPEG2Picture *_Nonnull picture);

/// Copies the held picture into NV12 planes: `luma` is width x height bytes, `chroma` is (width/2) x (height/2)
/// interleaved Cb/Cr pairs. Planar 4:2:0 converts directly; 4:2:2 keeps every other chroma row.
LibavMPEG2Result libav_mpeg2_copy_nv12(LibavMPEG2Decoder *_Nonnull decoder, uint8_t *_Nonnull luma,
                                       size_t lumaStride, uint8_t *_Nonnull chroma, size_t chromaStride);

/// Describes the held picture's planes when it was decoded into the page-aligned pool (always, for the 4:2:0 and 4:2:2
/// pictures MPEG-2 produces); UnsupportedFormat otherwise, and the caller falls back to `libav_mpeg2_copy_nv12`.
/// The planes stay valid until the next receive or flush unless the block is retained.
LibavMPEG2Result libav_mpeg2_planes(LibavMPEG2Decoder *_Nonnull decoder, LibavMPEG2Planes *_Nonnull planes);

/// A new reference to the held picture (its planes stay valid and its block is not reused for another picture until
/// `libav_mpeg2_picture_release`), so a GPU pass can read it after the next receive. NULL if no picture is held.
const void *_Nullable libav_mpeg2_picture_retain(LibavMPEG2Decoder *_Nonnull decoder);
/// Lets go of a reference from `libav_mpeg2_picture_retain`. Safe from any thread, also after the decoder closed.
void libav_mpeg2_picture_release(const void *_Nonnull picture);

/// Keeps a block's memory alive (for example while a Metal buffer wraps it). Safe from any thread.
void libav_mpeg2_block_retain(const void *_Nonnull block);
/// Lets go of a block retained above; its memory is freed after the last holder lets go. Safe from any thread.
void libav_mpeg2_block_release(const void *_Nonnull block);
/// The virtual memory page size blocks are aligned to.
size_t libav_mpeg2_page_size(void);

/// Drops buffered pictures and references, e.g. after a jump in the stream. The decoder stays open.
void libav_mpeg2_flush(LibavMPEG2Decoder *_Nonnull decoder);

/// libavcodec's version (major << 16 | minor << 8 | micro).
uint32_t libav_codec_version(void);
/// The FFmpeg release the libraries were built from, for example "9.0.2".
const char *_Nonnull libav_ffmpeg_version(void);
/// libavcodec's licence, for example "LGPL version 2.1 or later".
const char *_Nonnull libav_codec_license(void);
/// libavcodec's configure line.
const char *_Nonnull libav_codec_configuration(void);
/// libavutil's licence.
const char *_Nonnull libav_util_license(void);
/// libavutil's configure line.
const char *_Nonnull libav_util_configuration(void);

#ifdef __cplusplus
}
#endif

#endif
