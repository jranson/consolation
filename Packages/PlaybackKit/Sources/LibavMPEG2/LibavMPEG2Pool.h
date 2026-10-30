//
//  LibavMPEG2Pool.h
//  PlaybackKit
//
//  Private to the LibavMPEG2 target: the page-aligned picture pool behind the decoder's custom get_buffer2.
//

#ifndef LIBAV_MPEG2_POOL_H
#define LIBAV_MPEG2_POOL_H

#include "LibavMPEG2.h"

#include <libavcodec/avcodec.h>

typedef struct LibavMPEG2Pool LibavMPEG2Pool;

LibavMPEG2Pool *libav_mpeg2_pool_create(void);

/// Drops the pool's hold on its blocks. Blocks still used by frames or Metal buffers live until those let go.
void libav_mpeg2_pool_destroy(LibavMPEG2Pool *pool);

/// The decoder's get_buffer2. `context->opaque` must point at the pool.
int libav_mpeg2_pool_get_buffer(AVCodecContext *context, AVFrame *frame, int flags);

/// Describes `frame`'s planes when they live in one of the pool's blocks; UnsupportedFormat otherwise.
LibavMPEG2Result libav_mpeg2_pool_describe(LibavMPEG2Pool *pool, const AVFrame *frame, LibavMPEG2Planes *planes);

#endif
