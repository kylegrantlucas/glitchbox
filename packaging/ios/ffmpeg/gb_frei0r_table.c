/*
 * The statically linked frei0r plugins, looked up by module name by the
 * patched libavfilter/vf_frei0r.c (gb_frei0r_find). packaging/ios/ffmpeg.sh
 * compiles each plugin with its f0r_* entry points renamed to
 * gbf0r_<plugin>_<entry> and generates gb_frei0r_plugins.h, which defines
 * GB_FREI0R_PLUGINS(X) as X(<plugin>) for each of them.
 */
#include <stdint.h>
#include <stddef.h>
#include <strings.h>

#include <frei0r.h>

#include "gb_frei0r_plugins.h"

/* Mirrors GBFrei0rPlugin in the patched vf_frei0r.c. */
typedef struct GBFrei0rPlugin {
    const char *name;
    int  (*init)(void);
    void (*deinit)(void);
    void (*get_plugin_info)(f0r_plugin_info_t *info);
    void (*get_param_info)(f0r_param_info_t *info, int param_index);
    f0r_instance_t (*construct)(unsigned int width, unsigned int height);
    void (*destruct)(f0r_instance_t instance);
    void (*set_param_value)(f0r_instance_t instance, f0r_param_t param, int param_index);
    void (*get_param_value)(f0r_instance_t instance, f0r_param_t param, int param_index);
    void (*update)(f0r_instance_t instance, double time, const uint32_t *inframe, uint32_t *outframe);
} GBFrei0rPlugin;

const GBFrei0rPlugin *gb_frei0r_find(const char *name);

#define GB_DECLARE(p)                                                                    \
    int  gbf0r_##p##_init(void);                                                         \
    void gbf0r_##p##_deinit(void);                                                       \
    void gbf0r_##p##_get_plugin_info(f0r_plugin_info_t *info);                           \
    void gbf0r_##p##_get_param_info(f0r_param_info_t *info, int param_index);            \
    f0r_instance_t gbf0r_##p##_construct(unsigned int width, unsigned int height);       \
    void gbf0r_##p##_destruct(f0r_instance_t instance);                                  \
    void gbf0r_##p##_set_param_value(f0r_instance_t instance, f0r_param_t param, int i); \
    void gbf0r_##p##_get_param_value(f0r_instance_t instance, f0r_param_t param, int i); \
    void gbf0r_##p##_update(f0r_instance_t instance, double time,                        \
                            const uint32_t *inframe, uint32_t *outframe);
GB_FREI0R_PLUGINS(GB_DECLARE)

#define GB_ENTRY(p)                                                       \
    { #p, gbf0r_##p##_init, gbf0r_##p##_deinit,                           \
      gbf0r_##p##_get_plugin_info, gbf0r_##p##_get_param_info,            \
      gbf0r_##p##_construct, gbf0r_##p##_destruct,                        \
      gbf0r_##p##_set_param_value, gbf0r_##p##_get_param_value,           \
      gbf0r_##p##_update },
static const GBFrei0rPlugin plugins[] = { GB_FREI0R_PLUGINS(GB_ENTRY) };

/* The macOS build dlopen()s "<dir>/<name>.dylib" on a case-insensitive file
 * system, so names match case-insensitively here too. */
const GBFrei0rPlugin *gb_frei0r_find(const char *name)
{
    for (size_t i = 0; i < sizeof(plugins) / sizeof(plugins[0]); i++)
        if (!strcasecmp(plugins[i].name, name))
            return &plugins[i];
    return NULL;
}
