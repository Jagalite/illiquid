static inline int illiquid_subtitle_rect_copy_bgra(
    const AVSubtitleRect *rect, uint8_t *output, size_t output_size
) {
    if (!rect || rect->type != SUBTITLE_BITMAP || !output ||
        rect->w <= 0 || rect->h <= 0 || rect->w > 8192 || rect->h > 8192 ||
        rect->linesize[0] < rect->w || !rect->data[0] || !rect->data[1] ||
        rect->nb_colors <= 0 || rect->nb_colors > 256 ||
        (size_t)rect->w * rect->h > output_size / 4)
        return AVERROR_INVALIDDATA;
    for (int y = 0; y < rect->h; ++y) {
        const uint8_t *row = rect->data[0] + (size_t)y * rect->linesize[0];
        for (int x = 0; x < rect->w; ++x) {
            if (row[x] >= rect->nb_colors)
                return AVERROR_INVALIDDATA;
            uint32_t color;
            memcpy(&color, rect->data[1] + (size_t)row[x] * 4, sizeof(color));
            const unsigned int alpha = color >> 24;
            uint8_t *pixel = output + ((size_t)y * rect->w + x) * 4;
            pixel[0] = ((color & 255) * alpha + 127) / 255;
            pixel[1] = (((color >> 8) & 255) * alpha + 127) / 255;
            pixel[2] = (((color >> 16) & 255) * alpha + 127) / 255;
            pixel[3] = alpha;
        }
    }
    return 0;
}
