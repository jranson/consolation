//
//  LibavMPEG2Pool.c
//  PlaybackKit
//
//  A get_buffer2 that decodes straight into page-aligned blocks, so PlaybackKit can hand the planes to Metal with
//  `makeBuffer(bytesNoCopy:)` instead of copying them. Written against the documented get_buffer2 contract in
//  avcodec.h; Apache-2.0, no FFmpeg code copied.
//
//  One block holds a whole picture (Y, then Cb, then Cr). Each block counts two kinds of users:
//  - `inUse`: set while any AVBufferRef points at the block (libavcodec's references and received frames). Only a
//    block that is not in use is handed out again.
//  - `memoryRefs`: who keeps the memory alive: the pool, each AVBuffer and each Metal buffer wrapping it. The memory
//    is freed when the last one lets go, so a Metal buffer never outlives the bytes it wraps.
//  The AVBuffer free callback touches only its block, never the pool, so frames may outlive the decoder.
//

#include "LibavMPEG2Pool.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <libavutil/buffer.h>
#include <libavutil/pixdesc.h>

/// Blocks the pool keeps; MPEG-2 needs two references, the picture being decoded and the one held for output.
#define POOL_CAPACITY 24
/// Row strides are multiples of this (at least libavcodec's own linesize alignment).
#define STRIDE_ALIGNMENT 64
/// Plane starts are multiples of this.
#define PLANE_ALIGNMENT 256

typedef struct LibavMPEG2Block {
    uint8_t *base;
    size_t length;
    uint64_t serial;
    atomic_int inUse;
    atomic_int memoryRefs;
} LibavMPEG2Block;

struct LibavMPEG2Pool {
    pthread_mutex_t lock;
    LibavMPEG2Block *blocks[POOL_CAPACITY];
    int count;
    size_t blockLength;
    uint64_t nextSerial;
};

typedef struct {
    size_t offsets[3];
    int strides[3];
    size_t length;
} PlaneLayout;

static size_t align_up(size_t value, size_t alignment) {
    return (value + alignment - 1) / alignment * alignment;
}

size_t libav_mpeg2_page_size(void) {
    long size = sysconf(_SC_PAGESIZE);
    return size > 0 ? (size_t)size : 16384;
}

void libav_mpeg2_block_retain(const void *handle) {
    LibavMPEG2Block *block = (LibavMPEG2Block *)handle;
    atomic_fetch_add_explicit(&block->memoryRefs, 1, memory_order_relaxed);
}

void libav_mpeg2_block_release(const void *handle) {
    LibavMPEG2Block *block = (LibavMPEG2Block *)handle;
    if (atomic_fetch_sub_explicit(&block->memoryRefs, 1, memory_order_acq_rel) == 1) {
        munmap(block->base, block->length);
        free(block);
    }
}

static LibavMPEG2Block *block_create(size_t length, uint64_t serial) {
    LibavMPEG2Block *block = calloc(1, sizeof(LibavMPEG2Block));
    if (block == NULL) return NULL;
    // One VM region of its own per block: `makeBuffer(bytesNoCopy:)` requires memory from vm_allocate or mmap
    // (malloc, posix_memalign included, is disallowed), and the iOS simulator's Metal shares it over XPC, which
    // traps otherwise. Anonymous mappings are page-aligned and zero-filled, so a picture the decoder never fully
    // wrote (after an error) can't show stale process memory.
    void *memory = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (memory == MAP_FAILED) {
        free(block);
        return NULL;
    }
    block->base = memory;
    block->length = length;
    block->serial = serial;
    atomic_init(&block->inUse, 0);
    atomic_init(&block->memoryRefs, 1);
    return block;
}

LibavMPEG2Pool *libav_mpeg2_pool_create(void) {
    LibavMPEG2Pool *pool = calloc(1, sizeof(LibavMPEG2Pool));
    if (pool == NULL) return NULL;
    if (pthread_mutex_init(&pool->lock, NULL) != 0) {
        free(pool);
        return NULL;
    }
    return pool;
}

static void pool_drop_blocks(LibavMPEG2Pool *pool) {
    for (int index = 0; index < pool->count; index++) {
        libav_mpeg2_block_release(pool->blocks[index]);
        pool->blocks[index] = NULL;
    }
    pool->count = 0;
}

void libav_mpeg2_pool_destroy(LibavMPEG2Pool *pool) {
    if (pool == NULL) return;
    pthread_mutex_lock(&pool->lock);
    pool_drop_blocks(pool);
    pthread_mutex_unlock(&pool->lock);
    pthread_mutex_destroy(&pool->lock);
    free(pool);
}

/// Returns a block of `length` bytes marked in use with one memory reference for the caller, or NULL.
static LibavMPEG2Block *pool_acquire(LibavMPEG2Pool *pool, size_t length) {
    LibavMPEG2Block *found = NULL;
    pthread_mutex_lock(&pool->lock);
    if (pool->blockLength != length) {
        // A new picture size: blocks of the old size go once their last frame lets go.
        pool_drop_blocks(pool);
        pool->blockLength = length;
    }
    for (int index = 0; index < pool->count && found == NULL; index++) {
        int expected = 0;
        if (atomic_compare_exchange_strong(&pool->blocks[index]->inUse, &expected, 1)) found = pool->blocks[index];
    }
    if (found == NULL && pool->count < POOL_CAPACITY) {
        found = block_create(length, ++pool->nextSerial);
        if (found != NULL) {
            atomic_store(&found->inUse, 1);
            pool->blocks[pool->count++] = found;
        }
    }
    if (found != NULL) libav_mpeg2_block_retain(found);
    pthread_mutex_unlock(&pool->lock);
    return found;
}

/// The AVBuffer's free callback: the last AVBufferRef to the block is gone.
static void block_unused(void *opaque, uint8_t *data) {
    (void)data;
    LibavMPEG2Block *block = opaque;
    atomic_store_explicit(&block->inUse, 0, memory_order_release);
    libav_mpeg2_block_release(block);
}

/// Formats the pool decodes into: 8-bit planar Y'CbCr with half-width chroma (4:2:0 and 4:2:2).
static int format_supported(const AVPixFmtDescriptor *descriptor) {
    return descriptor != NULL && descriptor->nb_components == 3
        && (descriptor->flags & (AV_PIX_FMT_FLAG_PLANAR | AV_PIX_FMT_FLAG_HWACCEL | AV_PIX_FMT_FLAG_PAL
                                 | AV_PIX_FMT_FLAG_RGB)) == AV_PIX_FMT_FLAG_PLANAR
        && descriptor->comp[0].depth == 8 && descriptor->comp[1].depth == 8 && descriptor->comp[2].depth == 8
        && descriptor->log2_chroma_w == 1 && descriptor->log2_chroma_h <= 1;
}

/// Plane sizes from avcodec_align_dimensions2 (the decoder may write past the visible picture up to those), strides
/// rounded to the larger of libavcodec's linesize alignment and STRIDE_ALIGNMENT, one spare row after each plane,
/// and the block rounded up to whole pages so Metal can wrap it without a copy.
static PlaneLayout plane_layout(AVCodecContext *context, const AVFrame *frame,
                                const AVPixFmtDescriptor *descriptor) {
    int width = frame->width;
    int height = frame->height;
    int alignments[AV_NUM_DATA_POINTERS] = { 0 };
    avcodec_align_dimensions2(context, &width, &height, alignments);
    PlaneLayout layout = { { 0 }, { 0 }, 0 };
    size_t offset = 0;
    for (int plane = 0; plane < 3; plane++) {
        int shiftW = plane == 0 ? 0 : descriptor->log2_chroma_w;
        int shiftH = plane == 0 ? 0 : descriptor->log2_chroma_h;
        size_t planeWidth = (size_t)((width + (1 << shiftW) - 1) >> shiftW);
        size_t planeHeight = (size_t)((height + (1 << shiftH) - 1) >> shiftH);
        size_t alignment = alignments[plane] > STRIDE_ALIGNMENT ? (size_t)alignments[plane] : STRIDE_ALIGNMENT;
        size_t stride = align_up(planeWidth, alignment);
        offset = align_up(offset, PLANE_ALIGNMENT);
        layout.offsets[plane] = offset;
        layout.strides[plane] = (int)stride;
        offset += stride * (planeHeight + 1);
    }
    layout.length = align_up(offset, libav_mpeg2_page_size());
    return layout;
}

int libav_mpeg2_pool_get_buffer(AVCodecContext *context, AVFrame *frame, int flags) {
    LibavMPEG2Pool *pool = context->opaque;
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(frame->format);
    if (pool == NULL || !format_supported(descriptor) || frame->width <= 0 || frame->height <= 0) {
        return avcodec_default_get_buffer2(context, frame, flags);
    }
    PlaneLayout layout = plane_layout(context, frame, descriptor);
    LibavMPEG2Block *block = pool_acquire(pool, layout.length);
    if (block == NULL) return avcodec_default_get_buffer2(context, frame, flags);
    frame->buf[0] = av_buffer_create(block->base, block->length, block_unused, block, 0);
    if (frame->buf[0] == NULL) {
        block_unused(block, block->base);
        return AVERROR(ENOMEM);
    }
    for (int plane = 0; plane < 3; plane++) {
        frame->data[plane] = block->base + layout.offsets[plane];
        frame->linesize[plane] = layout.strides[plane];
    }
    frame->extended_data = frame->data;
    return 0;
}

static int pool_owns(LibavMPEG2Pool *pool, const LibavMPEG2Block *candidate) {
    int owned = 0;
    pthread_mutex_lock(&pool->lock);
    for (int index = 0; index < pool->count && !owned; index++) owned = pool->blocks[index] == candidate;
    pthread_mutex_unlock(&pool->lock);
    return owned;
}

LibavMPEG2Result libav_mpeg2_pool_describe(LibavMPEG2Pool *pool, const AVFrame *frame, LibavMPEG2Planes *planes) {
    if (frame->buf[0] == NULL || frame->buf[1] != NULL) return LibavMPEG2ResultUnsupportedFormat;
    const LibavMPEG2Block *block = av_buffer_get_opaque(frame->buf[0]);
    if (!pool_owns(pool, block) || frame->buf[0]->data != block->base) return LibavMPEG2ResultUnsupportedFormat;
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(frame->format);
    if (!format_supported(descriptor) || frame->linesize[1] != frame->linesize[2]) {
        return LibavMPEG2ResultUnsupportedFormat;
    }
    memset(planes, 0, sizeof(*planes));
    planes->block = block;
    planes->serial = block->serial;
    planes->base = block->base;
    planes->length = block->length;
    planes->lumaOffset = (size_t)(frame->data[0] - block->base);
    planes->blueOffset = (size_t)(frame->data[1] - block->base);
    planes->redOffset = (size_t)(frame->data[2] - block->base);
    planes->lumaStride = frame->linesize[0];
    planes->chromaStride = frame->linesize[1];
    planes->chromaRowStep = descriptor->log2_chroma_h == 1 ? 1 : 2;
    return LibavMPEG2ResultSuccess;
}
