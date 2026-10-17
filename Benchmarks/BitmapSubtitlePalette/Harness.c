/*
 * Portable qualification of the production bitmap palette conversion helper.
 * The runner provides baseline_convert and candidate_convert in separate
 * translation units using the same pinned FFmpeg headers and compiler flags.
 * Inputs and outputs are separate allocations, matching SubtitleDecoder's
 * fresh Data destination. In-place or overlapping conversion is not exercised.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>

int baseline_convert(const AVSubtitleRect *, uint8_t *, size_t);
int candidate_convert(const AVSubtitleRect *, uint8_t *, size_t);

typedef int (*Converter)(const AVSubtitleRect *, uint8_t *, size_t);

enum { fixture_count = 8, guard_bytes = 33, random_fixture_count = 1000 };
static const uint8_t sentinel = 0xCD;

typedef struct {
    const char *name;
    int width, height, colors, used_colors, padding;
} Workload;

static const Workload workloads[] = {
    { "tiny-1x1-256", 1, 1, 256, 256, 7 },
    { "tiny-8x8-256", 8, 8, 256, 256, 7 },
    { "threshold-511-256", 511, 1, 256, 256, 7 },
    { "threshold-512-256", 512, 1, 256, 256, 7 },
    { "threshold-513-256", 513, 1, 256, 256, 7 },
    { "small-16x16-256", 16, 16, 256, 256, 7 },
    { "small-32x16-256", 32, 16, 256, 256, 7 },
    { "dvd-720x64-4", 720, 64, 4, 4, 16 },
    { "caption-1280x96-sparse4", 1280, 96, 256, 4, 16 },
    { "caption-1280x96-dense256", 1280, 96, 256, 256, 16 },
    { "pgs-1920x216-256", 1920, 216, 256, 256, 32 },
    { "large-1920x1080-256", 1920, 1080, 256, 256, 32 },
};

typedef struct {
    AVSubtitleRect rect;
    uint8_t *source_allocation;
    uint8_t *palette_allocation;
    size_t output_bytes;
} Fixture;

static uint64_t checks = 0;
static uint64_t independent_pixel_checks = 0;

static void fail(const char *message) {
    fprintf(stderr, "Bitmap subtitle palette harness: %s\n", message);
    exit(1);
}

static void *allocate(size_t size) {
    void *result = malloc(size);
    if (!result) fail("allocation failed");
    return result;
}

static uint32_t next_random(uint32_t *state) {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return *state;
}

static Fixture make_fixture(const Workload *workload, uint32_t variant) {
    Fixture fixture = {0};
    AVSubtitleRect *rect = &fixture.rect;
    const int crop_x = 3, crop_y = 1;
    rect->type = SUBTITLE_BITMAP;
    rect->w = workload->width;
    rect->h = workload->height;
    rect->nb_colors = workload->colors;
    rect->linesize[0] = rect->w + crop_x + workload->padding;
    size_t source_bytes = (size_t)rect->linesize[0] * (rect->h + crop_y + 1);
    fixture.source_allocation = allocate(source_bytes);
    /* With fewer than 256 colors, every non-image source byte is invalid. */
    memset(fixture.source_allocation,
           rect->nb_colors < 256 ? rect->nb_colors : 255, source_bytes);
    rect->data[0] = fixture.source_allocation
        + (size_t)crop_y * rect->linesize[0] + crop_x;

    /* An unaligned palette with no bytes after its declared entries. */
    fixture.palette_allocation = allocate((size_t)rect->nb_colors * 4 + 1);
    rect->data[1] = fixture.palette_allocation + 1;
    uint32_t random = 0x83473621U ^ variant * 0x9E3779B9U
        ^ (uint32_t)rect->w * 0x85EBCA6BU ^ (uint32_t)rect->h;
    if (!random) random = 1;
    for (int i = 0; i < rect->nb_colors; ++i) {
        uint32_t color = next_random(&random);
        if (i == 0) color &= 0x00FFFFFFU;
        if (i == rect->nb_colors - 1) color |= 0xFF000000U;
        memcpy(rect->data[1] + (size_t)i * 4, &color, sizeof(color));
    }
    for (int y = 0; y < rect->h; ++y) {
        for (int x = 0; x < rect->w; ++x) {
            unsigned int choice = next_random(&random) % workload->used_colors;
            unsigned int index = workload->used_colors == 1 ? 0
                : choice * (unsigned int)(rect->nb_colors - 1)
                    / (unsigned int)(workload->used_colors - 1);
            rect->data[0][(size_t)y * rect->linesize[0] + x] = (uint8_t)index;
        }
    }
    fixture.output_bytes = (size_t)rect->w * rect->h * 4;
    return fixture;
}

static void free_fixture(Fixture *fixture) {
    free(fixture->source_allocation);
    free(fixture->palette_allocation);
    memset(fixture, 0, sizeof(*fixture));
}

/*
 * An independent rounding oracle: the exact integer product is at most 65025,
 * and division by the odd denominator 255 never lands at a half-integer.
 * Double precision therefore safely evaluates nearest-integer rounding here.
 */
static uint8_t expected_component(unsigned int component, unsigned int alpha) {
    return (uint8_t)((double)component * (double)alpha / 255.0 + 0.5);
}

static void write_expected_pixel(uint8_t *pixel, uint32_t color) {
    unsigned int alpha = color >> 24;
    pixel[0] = expected_component(color & 255, alpha);
    pixel[1] = expected_component((color >> 8) & 255, alpha);
    pixel[2] = expected_component((color >> 16) & 255, alpha);
    pixel[3] = (uint8_t)alpha;
}

/*
 * valid_prefix states precisely how many pixels should be written. For an
 * invalid index, all bytes from that pixel onward must retain the sentinel.
 * Metadata failures and null arguments must leave the whole output untouched.
 */
static void check_conversion(const char *label, const AVSubtitleRect *rect,
                             size_t capacity, size_t advertised_size,
                             int null_output, int expected_status,
                             size_t valid_prefix) {
    size_t allocation_size = capacity + 2 * guard_bytes;
    uint8_t *baseline = allocate(allocation_size);
    uint8_t *candidate = allocate(allocation_size);
    uint8_t *expected = allocate(allocation_size);
    memset(baseline, sentinel, allocation_size);
    memset(candidate, sentinel, allocation_size);
    memset(expected, sentinel, allocation_size);

    if (valid_prefix * 4 > capacity) fail("invalid verification fixture size");
    for (size_t i = 0; i < valid_prefix; ++i) {
        size_t y = i / (size_t)rect->w, x = i % (size_t)rect->w;
        unsigned int index = rect->data[0][y * (size_t)rect->linesize[0] + x];
        if (index >= (unsigned int)rect->nb_colors) fail("invalid oracle pixel");
        uint32_t color;
        memcpy(&color, rect->data[1] + (size_t)index * 4, sizeof(color));
        write_expected_pixel(expected + guard_bytes + i * 4, color);
    }

    int baseline_status = baseline_convert(rect,
        null_output ? NULL : baseline + guard_bytes, advertised_size);
    int candidate_status = candidate_convert(rect,
        null_output ? NULL : candidate + guard_bytes, advertised_size);
    if (baseline_status != expected_status || candidate_status != expected_status
        || memcmp(baseline, expected, allocation_size)
        || memcmp(candidate, expected, allocation_size)) {
        fprintf(stderr, "Failure in %s: expected status %d, baseline %d, candidate %d\n",
                label, expected_status, baseline_status, candidate_status);
        fail("status, independent pixel, partial-write, or output guard mismatch");
    }
    ++checks;
    independent_pixel_checks += valid_prefix;
    free(baseline);
    free(candidate);
    free(expected);
}

static void check_valid(const char *label, const Fixture *fixture) {
    check_conversion(label, &fixture->rect, fixture->output_bytes,
                     fixture->output_bytes, 0, 0, fixture->output_bytes / 4);
}

static void verify_exhaustive_alpha(void) {
    Workload workload = { "alpha/channel exhaustive", 256, 1, 256, 256, 7 };
    Fixture fixture = make_fixture(&workload, 0);
    for (int component = 0; component < 256; ++component)
        fixture.rect.data[0][component] = (uint8_t)component;
    for (unsigned int alpha = 0; alpha < 256; ++alpha) {
        for (unsigned int component = 0; component < 256; ++component) {
            uint32_t color = (alpha << 24) | (component << 16)
                | ((255 - component) << 8) | component;
            memcpy(fixture.rect.data[1] + component * 4, &color, sizeof(color));
        }
        check_valid(workload.name, &fixture);
    }
    /* Last palette entry is valid even when the entire image is one pixel. */
    fixture.rect.w = 1;
    fixture.output_bytes = 4;
    fixture.rect.data[0][0] = 255;
    check_valid("index 255 / one pixel", &fixture);
    free_fixture(&fixture);
}

static void verify_thresholds(void) {
    const int colors[] = { 1, 2, 4, 16, 32, 255, 256 };
    for (size_t i = 0; i < sizeof(colors) / sizeof(colors[0]); ++i) {
        for (int delta = -1; delta <= 1; ++delta) {
            int pixels = 2 * colors[i] + delta;
            if (pixels <= 0) continue;
            Workload workload = { "palette/pixel threshold", pixels, 1,
                                  colors[i], colors[i], 7 };
            Fixture fixture = make_fixture(&workload, (uint32_t)(i * 3 + delta + 1));
            check_valid(workload.name, &fixture);
            free_fixture(&fixture);
        }
    }
    const Workload boundary_cases[] = {
        { "maximum valid width", 8192, 1, 256, 256, 7 },
        { "maximum valid height", 1, 8192, 256, 256, 7 },
    };
    for (size_t i = 0; i < sizeof(boundary_cases) / sizeof(boundary_cases[0]); ++i) {
        Fixture fixture = make_fixture(&boundary_cases[i], (uint32_t)i);
        check_valid(boundary_cases[i].name, &fixture);
        free_fixture(&fixture);
    }
}

static void verify_invalid_arguments(void) {
    Workload workload = { "guards", 7, 5, 4, 4, 11 };
    Fixture fixture = make_fixture(&workload, 0);
    size_t capacity = fixture.output_bytes;
    const int invalid = AVERROR_INVALIDDATA;
    check_conversion("null rect", NULL, capacity, capacity, 0, invalid, 0);
    check_conversion("null output", &fixture.rect, capacity, capacity, 1, invalid, 0);
    check_conversion("zero output size", &fixture.rect, capacity, 0, 0, invalid, 0);
    check_conversion("short output size", &fixture.rect, capacity, capacity - 1, 0, invalid, 0);
    /* Extra permitted bytes are still outside the pixels written by the helper. */
    check_conversion("extra output capacity", &fixture.rect, capacity + 11,
                     capacity + 11, 0, 0, capacity / 4);

    AVSubtitleRect changed = fixture.rect;
    changed.w = 8192;
    changed.h = 8192;
    changed.linesize[0] = 8192;
    check_conversion("large declared image / small output", &changed,
                     capacity, capacity, 0, invalid, 0);
    changed = fixture.rect;
    changed.type = SUBTITLE_NONE;
    check_conversion("non-bitmap type", &changed, capacity, capacity, 0, invalid, 0);
    changed = fixture.rect;
    changed.data[0] = NULL;
    check_conversion("missing indices", &changed, capacity, capacity, 0, invalid, 0);
    changed = fixture.rect;
    changed.data[1] = NULL;
    check_conversion("missing palette", &changed, capacity, capacity, 0, invalid, 0);
    const int bad_dimensions[] = { -1, 0, 8193 };
    for (size_t i = 0; i < sizeof(bad_dimensions) / sizeof(bad_dimensions[0]); ++i) {
        changed = fixture.rect;
        changed.w = bad_dimensions[i];
        check_conversion("bad width", &changed, capacity, capacity, 0, invalid, 0);
        changed = fixture.rect;
        changed.h = bad_dimensions[i];
        check_conversion("bad height", &changed, capacity, capacity, 0, invalid, 0);
    }
    const int bad_colors[] = { -1, 0, 257 };
    for (size_t i = 0; i < sizeof(bad_colors) / sizeof(bad_colors[0]); ++i) {
        changed = fixture.rect;
        changed.nb_colors = bad_colors[i];
        check_conversion("bad palette size", &changed, capacity, capacity, 0, invalid, 0);
    }
    const int bad_strides[] = { -1, 0, 6 };
    for (size_t i = 0; i < sizeof(bad_strides) / sizeof(bad_strides[0]); ++i) {
        changed = fixture.rect;
        changed.linesize[0] = bad_strides[i];
        check_conversion("bad stride", &changed, capacity, capacity, 0, invalid, 0);
    }
    free_fixture(&fixture);
}

static void verify_randomized(void) {
    uint32_t random = 0x59BC28D1U;
    for (int i = 0; i < random_fixture_count; ++i) {
        int colors = 1 + (int)(next_random(&random) % 256);
        Workload workload = { "randomized", 1 + (int)(next_random(&random) % 257),
            1 + (int)(next_random(&random) % 33), colors, colors,
            1 + (int)(next_random(&random) % 31) };
        Fixture fixture = make_fixture(&workload, next_random(&random));
        check_valid(workload.name, &fixture);
        if (colors < 256) {
            size_t pixels = fixture.output_bytes / 4;
            size_t positions[] = { 0, pixels / 2, pixels - 1 };
            for (size_t j = 0; j < sizeof(positions) / sizeof(positions[0]); ++j) {
                size_t position = positions[j];
                size_t offset = (position / (size_t)fixture.rect.w)
                    * (size_t)fixture.rect.linesize[0] + position % (size_t)fixture.rect.w;
                uint8_t previous = fixture.rect.data[0][offset];
                fixture.rect.data[0][offset] = (uint8_t)colors;
                check_conversion("invalid palette index / valid prefix", &fixture.rect,
                    fixture.output_bytes, fixture.output_bytes, 0,
                    AVERROR_INVALIDDATA, position);
                fixture.rect.data[0][offset] = previous;
            }
        }
        free_fixture(&fixture);
    }
}

static void verify(void) {
    verify_exhaustive_alpha();
    verify_thresholds();
    verify_invalid_arguments();
    verify_randomized();
    for (size_t i = 0; i < sizeof(workloads) / sizeof(workloads[0]); ++i) {
        for (uint32_t variant = 0; variant < fixture_count; ++variant) {
            Fixture fixture = make_fixture(&workloads[i], variant);
            check_valid(workloads[i].name, &fixture);
            free_fixture(&fixture);
        }
    }
    printf("{\"status\":\"passed\",\"checks\":%" PRIu64
           ",\"native_calls\":%" PRIu64 ",\"independent_pixel_checks\":%" PRIu64
           ",\"alpha_channel_pairs\":65536,\"randomized_fixtures\":%d,"
           "\"workload_fixtures\":%zu}\n",
           checks, checks * 2, independent_pixel_checks, random_fixture_count,
           sizeof(workloads) / sizeof(workloads[0]) * (size_t)fixture_count);
}

static uint64_t timestamp(clockid_t clock_id) {
    struct timespec value;
    if (clock_gettime(clock_id, &value) != 0) fail("clock_gettime failed");
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static uint64_t hash_bytes(uint64_t hash, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; ++i)
        hash = (hash ^ bytes[i]) * UINT64_C(1099511628211);
    return hash;
}

static void measure(const char *variant, const Workload *workload, uint64_t iterations) {
    Converter convert;
    if (!strcmp(variant, "baseline")) convert = baseline_convert;
    else if (!strcmp(variant, "candidate")) convert = candidate_convert;
    else fail("variant must be baseline or candidate");

    Fixture fixtures[fixture_count];
    uint8_t *outputs[fixture_count];
    for (uint32_t i = 0; i < fixture_count; ++i) {
        fixtures[i] = make_fixture(workload, i);
        outputs[i] = allocate(fixtures[i].output_bytes);
        memset(outputs[i], sentinel, fixtures[i].output_bytes);
    }
    /* Eight full cycles establish resident source, palette, and output pages. */
    for (unsigned int cycle = 0; cycle < 8; ++cycle) {
        for (unsigned int i = 0; i < fixture_count; ++i) {
            if (convert(&fixtures[i].rect, outputs[i], fixtures[i].output_bytes))
                fail("warmup conversion failed");
        }
    }

    uint64_t receipt = 0;
    uint64_t wall_start = timestamp(CLOCK_MONOTONIC);
    uint64_t cpu_start = timestamp(CLOCK_PROCESS_CPUTIME_ID);
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        unsigned int i = (unsigned int)(iteration % fixture_count);
        if (convert(&fixtures[i].rect, outputs[i], fixtures[i].output_bytes))
            fail("measured conversion failed");
        receipt += outputs[i][0];
    }
    uint64_t cpu_ns = timestamp(CLOCK_PROCESS_CPUTIME_ID) - cpu_start;
    uint64_t wall_ns = timestamp(CLOCK_MONOTONIC) - wall_start;
    uint64_t checksum = UINT64_C(14695981039346656037);
    for (unsigned int i = 0; i < fixture_count; ++i)
        checksum = hash_bytes(checksum, outputs[i], fixtures[i].output_bytes);
    printf("{\"case\":\"%s\",\"variant\":\"%s\",\"iterations\":%" PRIu64
           ",\"wall_ns\":%" PRIu64 ",\"cpu_ns\":%" PRIu64
           ",\"checksum\":\"%016" PRIx64 "\",\"receipt\":\"%016" PRIx64
           "\",\"fixture_count\":%d,\"output_bytes_per_fixture\":%zu}\n",
           workload->name, variant, iterations, wall_ns, cpu_ns, checksum,
           receipt, fixture_count, fixtures[0].output_bytes);
    for (unsigned int i = 0; i < fixture_count; ++i) {
        free(outputs[i]);
        free_fixture(&fixtures[i]);
    }
}

static void list_workloads(void) {
    puts("[");
    for (size_t i = 0; i < sizeof(workloads) / sizeof(workloads[0]); ++i) {
        const Workload *workload = &workloads[i];
        printf("%s{\"name\":\"%s\",\"w\":%d,\"h\":%d,\"colors\":%d,"
               "\"index_pool_size\":%d,\"source_padding\":%d,\"fixture_count\":%d}",
               i ? ",\n" : "", workload->name, workload->width, workload->height,
               workload->colors, workload->used_colors, workload->padding, fixture_count);
    }
    puts("\n]");
}

static uint64_t parse_iterations(const char *value) {
    if (!*value) fail("iterations must be a decimal integer");
    for (const char *digit = value; *digit; ++digit)
        if (*digit < '0' || *digit > '9') fail("iterations must be a decimal integer");
    errno = 0;
    char *end;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno || *end || parsed == 0 || parsed >= 100000000ULL)
        fail("iterations must be between 1 and 99999999");
    return (uint64_t)parsed;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "list")) {
        list_workloads();
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "verify")) {
        verify();
        return 0;
    }
    if (argc == 5 && !strcmp(argv[1], "measure")) {
        for (size_t i = 0; i < sizeof(workloads) / sizeof(workloads[0]); ++i) {
            if (!strcmp(argv[3], workloads[i].name)) {
                measure(argv[2], &workloads[i], parse_iterations(argv[4]));
                return 0;
            }
        }
        fail("unknown case name (use list)");
    }
    fputs("Usage: palette-harness list | verify | measure baseline|candidate CASE ITERATIONS\n", stderr);
    return 2;
}
