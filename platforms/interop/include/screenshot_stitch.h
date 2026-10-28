#ifndef SCREENSHOT_STITCH_H
#define SCREENSHOT_STITCH_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1。亮度帧：宽 1..128，高 1..30000，count=width*height。
   帧的纵向像素不得缩小；source_width 保留原图宽度用于检测尺寸变化。
   每个 tracker 串行调用，销毁前完成所有调用；非法参数返回 -1。
   缓冲区只借用到函数返回，核心保留的锚点自行复制。 */
int32_t screenshot_stitch_abi_version(void);
/* 0 重复，1 追加，2 反向，3 尺寸变化，4 重叠不足，5 歧义，6 内容变化。 */
int32_t screenshot_stitch_match(const uint8_t *a, int32_t an, int32_t aw, int32_t ah, int32_t asw,
    const uint8_t *b, int32_t bn, int32_t bw, int32_t bh, int32_t bsw, int32_t *rows);
double screenshot_stitch_difference(const uint8_t *a, int32_t an, int32_t aw, int32_t ah, int32_t asw,
    const uint8_t *b, int32_t bn, int32_t bw, int32_t bh, int32_t bsw);
void *screenshot_stitch_tracker_create(void);
void screenshot_stitch_tracker_destroy(void *handle);
int32_t screenshot_stitch_tracker_reset(void *handle, const uint8_t *bytes, int32_t count,
    int32_t width, int32_t height, int32_t source_width);
int32_t screenshot_stitch_tracker_unmatched(void *handle);
/* 返回 0 首帧，1 追加，2 重复，3 恢复中，4 暂停；match/rows 为匹配原因。 */
int32_t screenshot_stitch_tracker_consume(void *handle, const uint8_t *bytes, int32_t count,
    int32_t width, int32_t height, int32_t source_width, double time, int32_t *match, int32_t *rows);
#ifdef __cplusplus
}
#endif
#endif
