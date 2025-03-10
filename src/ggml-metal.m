#import "ggml-metal.h"

#import "ggml-backend-impl.h"
#import "ggml.h"

#import <Foundation/Foundation.h>

#import <Metal/Metal.h>

#undef MIN
#undef MAX
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

#ifdef GGML_METAL_NDEBUG
#define GGML_METAL_LOG_INFO(...)
#define GGML_METAL_LOG_WARN(...)
#define GGML_METAL_LOG_ERROR(...)
#else
#define GGML_METAL_LOG_INFO(...)  ggml_metal_log(GGML_LOG_LEVEL_INFO, __VA_ARGS__)
#define GGML_METAL_LOG_WARN(...)  ggml_metal_log(GGML_LOG_LEVEL_WARN, __VA_ARGS__)
#define GGML_METAL_LOG_ERROR(...) ggml_metal_log(GGML_LOG_LEVEL_ERROR, __VA_ARGS__)
#endif

#define UNUSED(x) (void)(x)

#define GGML_MAX_CONCUR (2*GGML_DEFAULT_GRAPH_SIZE)

struct ggml_metal_buffer {
    const char * name;

    void   * data;
    size_t   size;

    id<MTLBuffer> metal;
};

struct ggml_metal_context {
    int n_cb;

    id<MTLDevice>       device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary>      library;

    id<MTLCommandBuffer>         command_buffers [GGML_METAL_MAX_COMMAND_BUFFERS];
    id<MTLComputeCommandEncoder> command_encoders[GGML_METAL_MAX_COMMAND_BUFFERS];

    dispatch_queue_t d_queue;

    int n_buffers;
    struct ggml_metal_buffer buffers[GGML_METAL_MAX_BUFFERS];

    int concur_list[GGML_MAX_CONCUR];
    int concur_list_len;

    // custom kernels
#define GGML_METAL_DECL_KERNEL(name) \
    id<MTLFunction>             function_##name; \
    id<MTLComputePipelineState> pipeline_##name

    GGML_METAL_DECL_KERNEL(add);
    GGML_METAL_DECL_KERNEL(add_row); // TODO: avoid this extra kernel, instead extend the "add" kernel to support broadcast
    GGML_METAL_DECL_KERNEL(mul);
    GGML_METAL_DECL_KERNEL(mul_row); // TODO: avoid this extra kernel, instead extend the "mul" kernel to support broadcast
    GGML_METAL_DECL_KERNEL(div);
    GGML_METAL_DECL_KERNEL(div_row);
    GGML_METAL_DECL_KERNEL(scale);
    GGML_METAL_DECL_KERNEL(scale_4);
    GGML_METAL_DECL_KERNEL(silu);
    GGML_METAL_DECL_KERNEL(relu);
    GGML_METAL_DECL_KERNEL(gelu);
    GGML_METAL_DECL_KERNEL(soft_max);
    GGML_METAL_DECL_KERNEL(soft_max_4);
    GGML_METAL_DECL_KERNEL(diag_mask_inf);
    GGML_METAL_DECL_KERNEL(diag_mask_inf_8);
    GGML_METAL_DECL_KERNEL(get_rows_f32);
    GGML_METAL_DECL_KERNEL(get_rows_f16);
    GGML_METAL_DECL_KERNEL(get_rows_q4_0);
    GGML_METAL_DECL_KERNEL(get_rows_q4_1);
    GGML_METAL_DECL_KERNEL(get_rows_q5_0);
    GGML_METAL_DECL_KERNEL(get_rows_q5_1);
    GGML_METAL_DECL_KERNEL(get_rows_q8_0);
    GGML_METAL_DECL_KERNEL(get_rows_q2_K);
    GGML_METAL_DECL_KERNEL(get_rows_q3_K);
    GGML_METAL_DECL_KERNEL(get_rows_q4_K);
    GGML_METAL_DECL_KERNEL(get_rows_q5_K);
    GGML_METAL_DECL_KERNEL(get_rows_q6_K);
    GGML_METAL_DECL_KERNEL(rms_norm);
    GGML_METAL_DECL_KERNEL(norm);
    GGML_METAL_DECL_KERNEL(mul_mv_f32_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_f16_f16);
    GGML_METAL_DECL_KERNEL(mul_mv_f16_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_f16_f32_1row);
    GGML_METAL_DECL_KERNEL(mul_mv_f16_f32_l4);
    GGML_METAL_DECL_KERNEL(mul_mv_q4_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q4_1_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q5_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q5_1_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q8_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q2_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q3_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q4_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q5_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mv_q6_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_f32_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_f16_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q4_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q4_1_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q5_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q5_1_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q8_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q2_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q3_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q4_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q5_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_q6_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_f32_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_f16_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q4_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q4_1_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q5_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q5_1_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q8_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q2_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q3_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q4_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q5_K_f32);
    GGML_METAL_DECL_KERNEL(mul_mm_id_q6_K_f32);
    GGML_METAL_DECL_KERNEL(rope_f32);
    GGML_METAL_DECL_KERNEL(rope_f16);
    GGML_METAL_DECL_KERNEL(alibi_f32);
    GGML_METAL_DECL_KERNEL(im2col_f16);
    GGML_METAL_DECL_KERNEL(argsort_f32_i32_asc);
    GGML_METAL_DECL_KERNEL(argsort_f32_i32_desc);
    GGML_METAL_DECL_KERNEL(cpy_f32_f16);
    GGML_METAL_DECL_KERNEL(cpy_f32_f32);
    GGML_METAL_DECL_KERNEL(cpy_f16_f16);
    GGML_METAL_DECL_KERNEL(concat);
    GGML_METAL_DECL_KERNEL(sqr);
    GGML_METAL_DECL_KERNEL(sum_rows);

#undef GGML_METAL_DECL_KERNEL
};

// MSL code
// TODO: move the contents here when ready
//       for now it is easier to work in a separate file
//static NSString * const msl_library_source = @"see metal.metal";

// Here to assist with NSBundle Path Hack
@interface GGMLMetalClass : NSObject
@end
@implementation GGMLMetalClass
@end

ggml_log_callback ggml_metal_log_callback = NULL;
void * ggml_metal_log_user_data = NULL;

void ggml_metal_log_set_callback(ggml_log_callback log_callback, void * user_data) {
    ggml_metal_log_callback  = log_callback;
    ggml_metal_log_user_data = user_data;
}

GGML_ATTRIBUTE_FORMAT(2, 3)
static void ggml_metal_log(enum ggml_log_level level, const char * format, ...){
    if (ggml_metal_log_callback != NULL) {
        va_list args;
        va_start(args, format);
        char buffer[128];
        int len = vsnprintf(buffer, 128, format, args);
        if (len < 128) {
            ggml_metal_log_callback(level, buffer, ggml_metal_log_user_data);
        } else {
            char* buffer2 = malloc(len+1);
            vsnprintf(buffer2, len+1, format, args);
            buffer2[len] = 0;
            ggml_metal_log_callback(level, buffer2, ggml_metal_log_user_data);
            free(buffer2);
        }
        va_end(args);
    }
}

struct ggml_metal_context * ggml_metal_init(int n_cb) {
    GGML_METAL_LOG_INFO("%s: allocating\n", __func__);

    id<MTLDevice> device;
    NSString * s;

#if TARGET_OS_OSX
    // Show all the Metal device instances in the system
    NSArray * devices = MTLCopyAllDevices();
    for (device in devices) {
        s = [device name];
        GGML_METAL_LOG_INFO("%s: found device: %s\n", __func__, [s UTF8String]);
    }
#endif

    // Pick and show default Metal device
    device = MTLCreateSystemDefaultDevice();
    s = [device name];
    GGML_METAL_LOG_INFO("%s: picking default device: %s\n", __func__, [s UTF8String]);

    // Configure context
    struct ggml_metal_context * ctx = malloc(sizeof(struct ggml_metal_context));
    ctx->device = device;
    ctx->n_cb   = MIN(n_cb, GGML_METAL_MAX_BUFFERS);
    ctx->queue  = [ctx->device newCommandQueue];
    ctx->n_buffers = 0;
    ctx->concur_list_len = 0;

    ctx->d_queue = dispatch_queue_create("ggml-metal", DISPATCH_QUEUE_CONCURRENT);

    // load library
    {
        NSBundle * bundle = nil;
#ifdef SWIFT_PACKAGE
        bundle = SWIFTPM_MODULE_BUNDLE;
#else
        bundle = [NSBundle bundleForClass:[GGMLMetalClass class]];
#endif
        NSError * error = nil;
        NSString * libPath = [bundle pathForResource:@"default" ofType:@"metallib"];
        if (libPath != nil) {
            NSURL * libURL = [NSURL fileURLWithPath:libPath];
            GGML_METAL_LOG_INFO("%s: loading '%s'\n", __func__, [libPath UTF8String]);
            ctx->library = [ctx->device newLibraryWithURL:libURL error:&error];
        } else {
            GGML_METAL_LOG_INFO("%s: default.metallib not found, loading from source\n", __func__);

            NSString * sourcePath;
            NSString * ggmlMetalPathResources = [[NSProcessInfo processInfo].environment objectForKey:@"GGML_METAL_PATH_RESOURCES"];
            if (ggmlMetalPathResources) {
                sourcePath = [ggmlMetalPathResources stringByAppendingPathComponent:@"ggml-metal.metal"];
            } else {
                sourcePath = [bundle pathForResource:@"ggml-metal" ofType:@"metal"];
            }
            if (sourcePath == nil) {
                GGML_METAL_LOG_WARN("%s: error: could not use bundle path to find ggml-metal.metal, falling back to trying cwd\n", __func__);
                sourcePath = @"ggml-metal.metal";
            }
            GGML_METAL_LOG_INFO("%s: loading '%s'\n", __func__, [sourcePath UTF8String]);
            NSString * src = [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&error];
            if (error) {
                GGML_METAL_LOG_ERROR("%s: error: %s\n", __func__, [[error description] UTF8String]);
                return NULL;
            }

            MTLCompileOptions* options = nil;
#ifdef GGML_QKK_64
            options = [MTLCompileOptions new];
            options.preprocessorMacros = @{ @"QK_K" : @(64) };
#endif
            ctx->library = [ctx->device newLibraryWithSource:src options:options error:&error];
        }

        if (error) {
            GGML_METAL_LOG_ERROR("%s: error: %s\n", __func__, [[error description] UTF8String]);
            return NULL;
        }
    }

#if TARGET_OS_OSX
    // print MTL GPU family:
    GGML_METAL_LOG_INFO("%s: GPU name:   %s\n", __func__, [[ctx->device name] UTF8String]);

    // determine max supported GPU family
    // https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
    // https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
    for (int i = MTLGPUFamilyApple1 + 20; i >= MTLGPUFamilyApple1; --i) {
        if ([ctx->device supportsFamily:i]) {
            GGML_METAL_LOG_INFO("%s: GPU family: MTLGPUFamilyApple%d (%d)\n", __func__, i - (int) MTLGPUFamilyApple1 + 1, i);
            break;
        }
    }

    GGML_METAL_LOG_INFO("%s: hasUnifiedMemory              = %s\n",       __func__, ctx->device.hasUnifiedMemory ? "true" : "false");
    GGML_METAL_LOG_INFO("%s: recommendedMaxWorkingSetSize  = %8.2f MB\n", __func__, ctx->device.recommendedMaxWorkingSetSize / 1e6);
    if (ctx->device.maxTransferRate != 0) {
        GGML_METAL_LOG_INFO("%s: maxTransferRate               = %8.2f MB/s\n", __func__, ctx->device.maxTransferRate / 1e6);
    } else {
        GGML_METAL_LOG_INFO("%s: maxTransferRate               = built-in GPU\n", __func__);
    }
#endif

    // load kernels
    {
        NSError * error = nil;

        /*
        GGML_METAL_LOG_INFO("%s: loaded %-32s %16p | th_max = %4d | th_width = %4d\n", __func__, "kernel_"#name, (void *) ctx->pipeline_##name, \
                (int) ctx->pipeline_##name.maxTotalThreadsPerThreadgroup, \
                (int) ctx->pipeline_##name.threadExecutionWidth); \
        */
#define GGML_METAL_ADD_KERNEL(name) \
        ctx->function_##name = [ctx->library newFunctionWithName:@"kernel_"#name]; \
        ctx->pipeline_##name = [ctx->device newComputePipelineStateWithFunction:ctx->function_##name error:&error]; \
        if (error) { \
            GGML_METAL_LOG_ERROR("%s: error: load pipeline error: %s\n", __func__, [[error description] UTF8String]); \
            return NULL; \
        }

        GGML_METAL_ADD_KERNEL(add);
        GGML_METAL_ADD_KERNEL(add_row);
        GGML_METAL_ADD_KERNEL(mul);
        GGML_METAL_ADD_KERNEL(mul_row);
        GGML_METAL_ADD_KERNEL(div);
        GGML_METAL_ADD_KERNEL(div_row);
        GGML_METAL_ADD_KERNEL(scale);
        GGML_METAL_ADD_KERNEL(scale_4);
        GGML_METAL_ADD_KERNEL(silu);
        GGML_METAL_ADD_KERNEL(relu);
        GGML_METAL_ADD_KERNEL(gelu);
        GGML_METAL_ADD_KERNEL(soft_max);
        GGML_METAL_ADD_KERNEL(soft_max_4);
        GGML_METAL_ADD_KERNEL(diag_mask_inf);
        GGML_METAL_ADD_KERNEL(diag_mask_inf_8);
        GGML_METAL_ADD_KERNEL(get_rows_f32);
        GGML_METAL_ADD_KERNEL(get_rows_f16);
        GGML_METAL_ADD_KERNEL(get_rows_q4_0);
        GGML_METAL_ADD_KERNEL(get_rows_q4_1);
        GGML_METAL_ADD_KERNEL(get_rows_q5_0);
        GGML_METAL_ADD_KERNEL(get_rows_q5_1);
        GGML_METAL_ADD_KERNEL(get_rows_q8_0);
        GGML_METAL_ADD_KERNEL(get_rows_q2_K);
        GGML_METAL_ADD_KERNEL(get_rows_q3_K);
        GGML_METAL_ADD_KERNEL(get_rows_q4_K);
        GGML_METAL_ADD_KERNEL(get_rows_q5_K);
        GGML_METAL_ADD_KERNEL(get_rows_q6_K);
        GGML_METAL_ADD_KERNEL(rms_norm);
        GGML_METAL_ADD_KERNEL(norm);
        GGML_METAL_ADD_KERNEL(mul_mv_f32_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_f16_f16);
        GGML_METAL_ADD_KERNEL(mul_mv_f16_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_f16_f32_1row);
        GGML_METAL_ADD_KERNEL(mul_mv_f16_f32_l4);
        GGML_METAL_ADD_KERNEL(mul_mv_q4_0_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q4_1_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q5_0_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q5_1_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q8_0_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q2_K_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q3_K_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q4_K_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q5_K_f32);
        GGML_METAL_ADD_KERNEL(mul_mv_q6_K_f32);
        if ([ctx->device supportsFamily:MTLGPUFamilyApple7]) {
            GGML_METAL_ADD_KERNEL(mul_mm_f32_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_f16_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q4_0_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q4_1_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q5_0_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q5_1_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q8_0_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q2_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q3_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q4_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q5_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_q6_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_f32_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_f16_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q4_0_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q4_1_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q5_0_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q5_1_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q8_0_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q2_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q3_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q4_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q5_K_f32);
            GGML_METAL_ADD_KERNEL(mul_mm_id_q6_K_f32);
        }
        GGML_METAL_ADD_KERNEL(rope_f32);
        GGML_METAL_ADD_KERNEL(rope_f16);
        GGML_METAL_ADD_KERNEL(alibi_f32);
        GGML_METAL_ADD_KERNEL(im2col_f16);
        GGML_METAL_ADD_KERNEL(argsort_f32_i32_asc);
        GGML_METAL_ADD_KERNEL(argsort_f32_i32_desc);
        GGML_METAL_ADD_KERNEL(cpy_f32_f16);
        GGML_METAL_ADD_KERNEL(cpy_f32_f32);
        GGML_METAL_ADD_KERNEL(cpy_f16_f16);
        GGML_METAL_ADD_KERNEL(concat);
        GGML_METAL_ADD_KERNEL(sqr);
        GGML_METAL_ADD_KERNEL(sum_rows);

#undef GGML_METAL_ADD_KERNEL
    }

    return ctx;
}

void ggml_metal_free(struct ggml_metal_context * ctx) {
    GGML_METAL_LOG_INFO("%s: deallocating\n", __func__);
#define GGML_METAL_DEL_KERNEL(name) \
    [ctx->function_##name release]; \
    [ctx->pipeline_##name release];

    GGML_METAL_DEL_KERNEL(add);
    GGML_METAL_DEL_KERNEL(add_row);
    GGML_METAL_DEL_KERNEL(mul);
    GGML_METAL_DEL_KERNEL(mul_row);
    GGML_METAL_DEL_KERNEL(div);
    GGML_METAL_DEL_KERNEL(div_row);
    GGML_METAL_DEL_KERNEL(scale);
    GGML_METAL_DEL_KERNEL(scale_4);
    GGML_METAL_DEL_KERNEL(silu);
    GGML_METAL_DEL_KERNEL(relu);
    GGML_METAL_DEL_KERNEL(gelu);
    GGML_METAL_DEL_KERNEL(soft_max);
    GGML_METAL_DEL_KERNEL(soft_max_4);
    GGML_METAL_DEL_KERNEL(diag_mask_inf);
    GGML_METAL_DEL_KERNEL(diag_mask_inf_8);
    GGML_METAL_DEL_KERNEL(get_rows_f32);
    GGML_METAL_DEL_KERNEL(get_rows_f16);
    GGML_METAL_DEL_KERNEL(get_rows_q4_0);
    GGML_METAL_DEL_KERNEL(get_rows_q4_1);
    GGML_METAL_DEL_KERNEL(get_rows_q5_0);
    GGML_METAL_DEL_KERNEL(get_rows_q5_1);
    GGML_METAL_DEL_KERNEL(get_rows_q8_0);
    GGML_METAL_DEL_KERNEL(get_rows_q2_K);
    GGML_METAL_DEL_KERNEL(get_rows_q3_K);
    GGML_METAL_DEL_KERNEL(get_rows_q4_K);
    GGML_METAL_DEL_KERNEL(get_rows_q5_K);
    GGML_METAL_DEL_KERNEL(get_rows_q6_K);
    GGML_METAL_DEL_KERNEL(rms_norm);
    GGML_METAL_DEL_KERNEL(norm);
    GGML_METAL_DEL_KERNEL(mul_mv_f32_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_f16_f16);
    GGML_METAL_DEL_KERNEL(mul_mv_f16_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_f16_f32_1row);
    GGML_METAL_DEL_KERNEL(mul_mv_f16_f32_l4);
    GGML_METAL_DEL_KERNEL(mul_mv_q4_0_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q4_1_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q5_0_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q5_1_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q8_0_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q2_K_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q3_K_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q4_K_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q5_K_f32);
    GGML_METAL_DEL_KERNEL(mul_mv_q6_K_f32);
    if ([ctx->device supportsFamily:MTLGPUFamilyApple7]) {
        GGML_METAL_DEL_KERNEL(mul_mm_f32_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_f16_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q4_0_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q4_1_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q5_0_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q5_1_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q8_0_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q2_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q3_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q4_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q5_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_q6_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_f32_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_f16_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q4_0_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q4_1_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q5_0_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q5_1_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q8_0_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q2_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q3_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q4_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q5_K_f32);
        GGML_METAL_DEL_KERNEL(mul_mm_id_q6_K_f32);
    }
    GGML_METAL_DEL_KERNEL(rope_f32);
    GGML_METAL_DEL_KERNEL(rope_f16);
    GGML_METAL_DEL_KERNEL(alibi_f32);
    GGML_METAL_DEL_KERNEL(im2col_f16);
    GGML_METAL_DEL_KERNEL(argsort_f32_i32_asc);
    GGML_METAL_DEL_KERNEL(argsort_f32_i32_desc);
    GGML_METAL_DEL_KERNEL(cpy_f32_f16);
    GGML_METAL_DEL_KERNEL(cpy_f32_f32);
    GGML_METAL_DEL_KERNEL(cpy_f16_f16);
    GGML_METAL_DEL_KERNEL(concat);
    GGML_METAL_DEL_KERNEL(sqr);
    GGML_METAL_DEL_KERNEL(sum_rows);

#undef GGML_METAL_DEL_KERNEL

    for (int i = 0; i < ctx->n_buffers; ++i) {
        [ctx->buffers[i].metal release];
    }

    [ctx->library release];
    [ctx->queue release];
    [ctx->device release];

    dispatch_release(ctx->d_queue);

    free(ctx);
}

void * ggml_metal_host_malloc(size_t n) {
    void * data = NULL;
    const int result = posix_memalign((void **) &data, sysconf(_SC_PAGESIZE), n);
    if (result != 0) {
        GGML_METAL_LOG_ERROR("%s: error: posix_memalign failed\n", __func__);
        return NULL;
    }

    return data;
}

void ggml_metal_host_free(void * data) {
    free(data);
}

void ggml_metal_set_n_cb(struct ggml_metal_context * ctx, int n_cb) {
    ctx->n_cb = MIN(n_cb, GGML_METAL_MAX_BUFFERS);
}

int ggml_metal_if_optimized(struct ggml_metal_context * ctx) {
    return ctx->concur_list_len;
}

int * ggml_metal_get_concur_list(struct ggml_metal_context * ctx) {
    return ctx->concur_list;
}

// temporarily defined here for compatibility between ggml-backend and the old API
struct ggml_backend_metal_buffer_context {
    void * data;

    id<MTLBuffer> metal;
};

// finds the Metal buffer that contains the tensor data on the GPU device
// the assumption is that there is 1-to-1 mapping between the host and device memory buffers, so we can find the
// Metal buffer based on the host memory pointer
//
static id<MTLBuffer> ggml_metal_get_buffer(struct ggml_metal_context * ctx, struct ggml_tensor * t, size_t * offs) {
    //GGML_METAL_LOG_INFO("%s: data tensor '%16s', offs_data = %8ld, offs_eval = %8ld, offs_cach = %8ld\n", __func__, t->name, offs_data, offs_eval, offs_cach);

    const int64_t tsize = ggml_nbytes(t);

    // compatibility with ggml-backend
    if (t->buffer && t->buffer->buft == ggml_backend_metal_buffer_type()) {
        struct ggml_backend_metal_buffer_context * buf_ctx = (struct ggml_backend_metal_buffer_context *) t->buffer->context;

        const int64_t ioffs = (int64_t) t->data - (int64_t) buf_ctx->data;

        GGML_ASSERT(ioffs >= 0 && ioffs + tsize <= (int64_t) t->buffer->size);

        *offs = (size_t) ioffs;

        return buf_ctx->metal;
    }

    // find the view that contains the tensor fully
    for (int i = 0; i < ctx->n_buffers; ++i) {
        const int64_t ioffs = (int64_t) t->data - (int64_t) ctx->buffers[i].data;

        //GGML_METAL_LOG_INFO("ioffs = %10ld, tsize = %10ld, sum = %10ld, ctx->buffers[%d].size = %10ld, name = %s\n", ioffs, tsize, ioffs + tsize, i, ctx->buffers[i].size, ctx->buffers[i].name);
        if (ioffs >= 0 && ioffs + tsize <= (int64_t) ctx->buffers[i].size) {
            *offs = (size_t) ioffs;

            //GGML_METAL_LOG_INFO("%s: '%s' tensor '%16s', offs = %8ld\n", __func__, ctx->buffers[i].name, t->name, *offs);

            return ctx->buffers[i].metal;
        }
    }

    GGML_METAL_LOG_ERROR("%s: error: buffer is nil\n", __func__);

    return nil;
}

bool ggml_metal_add_buffer(
        struct ggml_metal_context * ctx,
                     const char * name,
                           void * data,
                         size_t   size,
                         size_t   max_size) {
    if (ctx->n_buffers >= GGML_METAL_MAX_BUFFERS) {
        GGML_METAL_LOG_ERROR("%s: error: too many buffers\n", __func__);
        return false;
    }

    if (data) {
        // verify that the buffer does not overlap with any of the existing buffers
        for (int i = 0; i < ctx->n_buffers; ++i) {
            const int64_t ioffs = (int64_t) data - (int64_t) ctx->buffers[i].data;

            if (ioffs >= 0 && ioffs < (int64_t) ctx->buffers[i].size) {
                GGML_METAL_LOG_ERROR("%s: error: buffer '%s' overlaps with '%s'\n", __func__, name, ctx->buffers[i].name);
                return false;
            }
        }

        const size_t size_page = sysconf(_SC_PAGESIZE);

        size_t size_aligned = size;
        if ((size_aligned % size_page) != 0) {
            size_aligned += (size_page - (size_aligned % size_page));
        }

        // the buffer fits into the max buffer size allowed by the device
        if (size_aligned <= ctx->device.maxBufferLength) {
            ctx->buffers[ctx->n_buffers].name = name;
            ctx->buffers[ctx->n_buffers].data = data;
            ctx->buffers[ctx->n_buffers].size = size;

            ctx->buffers[ctx->n_buffers].metal = [ctx->device newBufferWithBytesNoCopy:data length:size_aligned options:MTLResourceStorageModeShared deallocator:nil];

            if (ctx->buffers[ctx->n_buffers].metal == nil) {
                GGML_METAL_LOG_ERROR("%s: error: failed to allocate '%-16s' buffer, size = %8.2f MB\n", __func__, name, size_aligned / 1e6);
                return false;
            }

            GGML_METAL_LOG_INFO("%s: allocated '%-16s' buffer, size = %8.2f MB", __func__, name, size_aligned / 1e6);

            ++ctx->n_buffers;
        } else {
            // this overlap between the views will guarantee that the tensor with the maximum size will fully fit into
            // one of the views
            const size_t size_ovlp = ((max_size + size_page - 1) / size_page + 1) * size_page; // round-up 2 pages just in case
            const size_t size_step = ctx->device.maxBufferLength - size_ovlp;
            const size_t size_view = ctx->device.maxBufferLength;

            for (size_t i = 0; i < size; i += size_step) {
                const size_t size_step_aligned = (i + size_view <= size) ? size_view : (size_aligned - i);

                ctx->buffers[ctx->n_buffers].name = name;
                ctx->buffers[ctx->n_buffers].data = (void *) ((uint8_t *) data + i);
                ctx->buffers[ctx->n_buffers].size = size_step_aligned;

                ctx->buffers[ctx->n_buffers].metal = [ctx->device newBufferWithBytesNoCopy:(void *) ((uint8_t *) data + i) length:size_step_aligned options:MTLResourceStorageModeShared deallocator:nil];

                if (ctx->buffers[ctx->n_buffers].metal == nil) {
                    GGML_METAL_LOG_ERROR("%s: error: failed to allocate '%-16s' buffer, size = %8.2f MB\n", __func__, name, size_step_aligned / 1e6);
                    return false;
                }

                GGML_METAL_LOG_INFO("%s: allocated '%-16s' buffer, size = %8.2f MB, offs = %12ld", __func__, name, size_step_aligned / 1e6, i);
                if (i + size_step < size) {
                    GGML_METAL_LOG_INFO("\n");
                }

                ++ctx->n_buffers;
            }
        }

#if TARGET_OS_OSX
        GGML_METAL_LOG_INFO(", (%8.2f / %8.2f)",
                ctx->device.currentAllocatedSize / 1e6,
                ctx->device.recommendedMaxWorkingSetSize / 1e6);

        if (ctx->device.currentAllocatedSize > ctx->device.recommendedMaxWorkingSetSize) {
            GGML_METAL_LOG_WARN("%s: warning: current allocated size is greater than the recommended max working set size\n", __func__);
        } else {
            GGML_METAL_LOG_INFO("\n");
        }
#else
        GGML_METAL_LOG_INFO(", (%8.2f)\n", ctx->device.currentAllocatedSize / 1e6);
#endif
    }

    return true;
}

void ggml_metal_set_tensor(
        struct ggml_metal_context * ctx,
        struct ggml_tensor * t) {
    size_t offs;
    id<MTLBuffer> id_dst = ggml_metal_get_buffer(ctx, t, &offs);

    memcpy((void *) ((uint8_t *) id_dst.contents + offs), t->data, ggml_nbytes(t));
}

void ggml_metal_get_tensor(
        struct ggml_metal_context * ctx,
        struct ggml_tensor * t) {
    size_t offs;
    id<MTLBuffer> id_src = ggml_metal_get_buffer(ctx, t, &offs);

    memcpy(t->data, (void *) ((uint8_t *) id_src.contents + offs), ggml_nbytes(t));
}

void ggml_metal_graph_find_concurrency(
        struct ggml_metal_context * ctx,
        struct ggml_cgraph * gf, bool check_mem) {
    int search_depth = gf->n_nodes; //we only find concurrency in this range to avoid wasting too much time
    int nodes_unused[GGML_MAX_CONCUR];

    for (int i = 0; i < GGML_MAX_CONCUR; i++) { ctx->concur_list[i] = 0; }
    for (int i = 0; i < gf->n_nodes;     i++) { nodes_unused[i]     = 1; }
    ctx->concur_list_len = 0;

    int n_left    = gf->n_nodes;
    int n_start   = 0; // all nodes before n_start at nodes_unused array have been sorted and store back to ctx->concur_list
    int level_pos = 0; // at ctx->concur_list, the last layer (level) ends at level_pos

    while (n_left > 0) {
        // number of nodes at a layer (that can be issued concurrently)
        int concurrency = 0;
        for (int i = n_start; i < ((n_start + search_depth > gf->n_nodes) ? gf->n_nodes : n_start + search_depth); i++) {
            if (nodes_unused[i]) {
                // if the requirements for gf->nodes[i] are satisfied
                int exe_flag = 1;

                // scan all srcs
                for (int src_ind = 0; src_ind < GGML_MAX_SRC; src_ind++) {
                    struct ggml_tensor * src_cur = gf->nodes[i]->src[src_ind];
                    if (src_cur) {
                        // if is leaf nodes it's satisfied.
                        // TODO: ggml_is_leaf()
                        if (src_cur->op == GGML_OP_NONE && src_cur->grad == NULL) {
                            continue;
                        }

                        // otherwise this src should be the output from previous nodes.
                        int is_found = 0;

                        // scan 2*search_depth back because we inserted barrier.
                        //for (int j = ((level_pos - 2*search_depth) < 0 ? 0 : (level_pos - 2*search_depth)); j < level_pos; j++) {
                        for (int j = MAX(0, level_pos - 2*search_depth); j < level_pos; j++) {
                            if (ctx->concur_list[j] >= 0 && gf->nodes[ctx->concur_list[j]] == src_cur) {
                                is_found = 1;
                                break;
                            }
                        }
                        if (is_found == 0) {
                            exe_flag = 0;
                            break;
                        }
                    }
                }
                if (exe_flag && check_mem) {
                    // check if nodes[i]'s data will be overwritten by a node before nodes[i].
                    // if node[5] and node[3] write to the same memory region, then we can't issue node[5] before node[3]
                    int64_t data_start = (int64_t) gf->nodes[i]->data;
                    int64_t length     = (int64_t) ggml_nbytes(gf->nodes[i]);
                    for (int j = n_start; j < i; j++) {
                        if (nodes_unused[j] && gf->nodes[j]->op != GGML_OP_RESHAPE \
                                            && gf->nodes[j]->op != GGML_OP_VIEW \
                                            && gf->nodes[j]->op != GGML_OP_TRANSPOSE \
                                            && gf->nodes[j]->op != GGML_OP_PERMUTE) {
                            if (((int64_t)gf->nodes[j]->data) >= data_start + length || \
                                ((int64_t)gf->nodes[j]->data) + (int64_t) ggml_nbytes(gf->nodes[j]) <= data_start) {
                                continue;
                            }

                            exe_flag = 0;
                        }
                    }
                }
                if (exe_flag) {
                    ctx->concur_list[level_pos + concurrency] = i;
                    nodes_unused[i] = 0;
                    concurrency++;
                    ctx->concur_list_len++;
                }
            }
        }
        n_left -= concurrency;
        // adding a barrier different layer
        ctx->concur_list[level_pos + concurrency] = -1;
        ctx->concur_list_len++;
        // jump all sorted nodes at nodes_bak
        while (!nodes_unused[n_start]) {
            n_start++;
        }
        level_pos += concurrency + 1;
    }

    if (ctx->concur_list_len > GGML_MAX_CONCUR) {
        GGML_METAL_LOG_WARN("%s: too many elements for metal ctx->concur_list!\n", __func__);
    }
}

static bool ggml_metal_supports_op(const struct ggml_tensor * op) {
    switch (op->op) {
        case GGML_OP_UNARY:
            switch (ggml_get_unary_op(op)) {
                case GGML_UNARY_OP_SILU:
                case GGML_UNARY_OP_RELU:
                case GGML_UNARY_OP_GELU:
                    return true;
                default:
                    return false;
            }
            break;
        case GGML_OP_NONE:
        case GGML_OP_RESHAPE:
        case GGML_OP_VIEW:
        case GGML_OP_TRANSPOSE:
        case GGML_OP_PERMUTE:
        case GGML_OP_CONCAT:
        case GGML_OP_ADD:
        case GGML_OP_MUL:
        case GGML_OP_DIV:
        case GGML_OP_SCALE:
        case GGML_OP_SQR:
        case GGML_OP_SUM_ROWS:
        case GGML_OP_SOFT_MAX:
        case GGML_OP_RMS_NORM:
        case GGML_OP_NORM:
        case GGML_OP_ALIBI:
        case GGML_OP_ROPE:
        case GGML_OP_IM2COL:
        case GGML_OP_ARGSORT:
        case GGML_OP_DUP:
        case GGML_OP_CPY:
        case GGML_OP_CONT:
            return true;
        case GGML_OP_DIAG_MASK_INF:
        case GGML_OP_GET_ROWS:
            {
                return op->ne[0] % 4 == 0;
            } break;
        case GGML_OP_MUL_MAT:
        case GGML_OP_MUL_MAT_ID:
            {
                struct ggml_tensor * a;
                struct ggml_tensor * b; UNUSED(b);
                if (op->op == GGML_OP_MUL_MAT) {
                    a = op->src[0];
                    b = op->src[1];
                } else {
                    a = op->src[2];
                    b = op->src[1];
                }
                if (a->ne[3] != 1) {
                    return false;
                }
                if (ggml_is_quantized(a->type) && a->ne[2] != 1) {
                    return false;
                }
                return true;
            } break;
        default:
            return false;
    }
}
void ggml_metal_graph_compute(
        struct ggml_metal_context * ctx,
               struct ggml_cgraph * gf) {
    @autoreleasepool {

    // if there is ctx->concur_list, dispatch concurrently
    // else fallback to serial dispatch
    MTLComputePassDescriptor * edesc = MTLComputePassDescriptor.computePassDescriptor;

    const bool has_concur = ctx->concur_list_len && ctx->concur_list_len <= GGML_MAX_CONCUR;

    const int n_nodes  = has_concur ? ctx->concur_list_len      : gf->n_nodes;
    edesc.dispatchType = has_concur ? MTLDispatchTypeConcurrent : MTLDispatchTypeSerial;

    // create multiple command buffers and enqueue them
    // then, we encode the graph into the command buffers in parallel

    const int n_cb = ctx->n_cb;

    for (int i = 0; i < n_cb; ++i) {
        ctx->command_buffers[i] = [ctx->queue commandBuffer];

        // enqueue the command buffers in order to specify their execution order
        [ctx->command_buffers[i] enqueue];

        ctx->command_encoders[i] = [ctx->command_buffers[i] computeCommandEncoderWithDescriptor: edesc];
    }

    for (int cb_idx = 0; cb_idx < n_cb; ++cb_idx) {
        const int n_nodes_per_cb = (n_nodes + n_cb - 1) / n_cb;

        dispatch_async(ctx->d_queue, ^{
            size_t offs_src0 = 0;
            size_t offs_src1 = 0;
            size_t offs_dst  = 0;

            id<MTLCommandBuffer> command_buffer  = ctx->command_buffers[cb_idx];
            id<MTLComputeCommandEncoder> encoder = ctx->command_encoders[cb_idx];

            const int node_start =                                      (cb_idx + 0) * n_nodes_per_cb;
            const int node_end   = MIN((cb_idx == n_cb - 1) ? n_nodes : (cb_idx + 1) * n_nodes_per_cb, n_nodes);

            for (int ind = node_start; ind < node_end; ++ind) {
                const int i = has_concur ? ctx->concur_list[ind] : ind;

                if (i == -1) {
                    [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
                    continue;
                }

                //GGML_METAL_LOG_INFO("%s: encoding node %3d, op = %8s\n", __func__, i, ggml_op_name(gf->nodes[i]->op));

                struct ggml_tensor * src0 = gf->nodes[i]->src[0];
                struct ggml_tensor * src1 = gf->nodes[i]->src[1];
                struct ggml_tensor * dst  = gf->nodes[i];

                switch (dst->op) {
                    case GGML_OP_NONE:
                    case GGML_OP_RESHAPE:
                    case GGML_OP_VIEW:
                    case GGML_OP_TRANSPOSE:
                    case GGML_OP_PERMUTE:
                        {
                            // noop -> next node
                        } continue;
                    default:
                        {
                        } break;
                }

                GGML_ASSERT(ggml_metal_supports_op(dst));

                const int64_t  ne00 = src0 ? src0->ne[0] : 0;
                const int64_t  ne01 = src0 ? src0->ne[1] : 0;
                const int64_t  ne02 = src0 ? src0->ne[2] : 0;
                const int64_t  ne03 = src0 ? src0->ne[3] : 0;

                const uint64_t nb00 = src0 ? src0->nb[0] : 0;
                const uint64_t nb01 = src0 ? src0->nb[1] : 0;
                const uint64_t nb02 = src0 ? src0->nb[2] : 0;
                const uint64_t nb03 = src0 ? src0->nb[3] : 0;

                const int64_t  ne10 = src1 ? src1->ne[0] : 0;
                const int64_t  ne11 = src1 ? src1->ne[1] : 0;
                const int64_t  ne12 = src1 ? src1->ne[2] : 0;
                const int64_t  ne13 = src1 ? src1->ne[3] : 0; UNUSED(ne13);

                const uint64_t nb10 = src1 ? src1->nb[0] : 0;
                const uint64_t nb11 = src1 ? src1->nb[1] : 0;
                const uint64_t nb12 = src1 ? src1->nb[2] : 0;
                const uint64_t nb13 = src1 ? src1->nb[3] : 0; UNUSED(nb13);

                const int64_t  ne0  = dst ? dst->ne[0] : 0;
                const int64_t  ne1  = dst ? dst->ne[1] : 0;
                const int64_t  ne2  = dst ? dst->ne[2] : 0;
                const int64_t  ne3  = dst ? dst->ne[3] : 0;

                const uint64_t nb0  = dst ? dst->nb[0] : 0;
                const uint64_t nb1  = dst ? dst->nb[1] : 0;
                const uint64_t nb2  = dst ? dst->nb[2] : 0;
                const uint64_t nb3  = dst ? dst->nb[3] : 0;

                const enum ggml_type src0t = src0 ? src0->type : GGML_TYPE_COUNT;
                const enum ggml_type src1t = src1 ? src1->type : GGML_TYPE_COUNT;
                const enum ggml_type dstt  = dst  ? dst->type  : GGML_TYPE_COUNT;

                id<MTLBuffer> id_src0 = src0 ? ggml_metal_get_buffer(ctx, src0, &offs_src0) : nil;
                id<MTLBuffer> id_src1 = src1 ? ggml_metal_get_buffer(ctx, src1, &offs_src1) : nil;
                id<MTLBuffer> id_dst  = dst  ? ggml_metal_get_buffer(ctx, dst,  &offs_dst)  : nil;

                //GGML_METAL_LOG_INFO("%s: op - %s\n", __func__, ggml_op_name(dst->op));
                //if (src0) {
                //    GGML_METAL_LOG_INFO("%s: src0 - %4s [%5lld, %5lld, %5lld], %d, %s\n", __func__, ggml_type_name(src0t), ne00, ne01, ne02,
                //            ggml_is_contiguous(src0), src0->name);
                //}
                //if (src1) {
                //    GGML_METAL_LOG_INFO("%s: src1 - %4s [%5lld, %5lld, %5lld], %d, %s\n", __func__, ggml_type_name(src1t), ne10, ne11, ne12,
                //            ggml_is_contiguous(src1), src1->name);
                //}
                //if (dst) {
                //    GGML_METAL_LOG_INFO("%s: dst  - %4s [%5lld, %5lld, %5lld], 1, %s\n",  __func__, ggml_type_name(dstt),  ne0,  ne1,  ne2,
                //            dst->name);
                //}

                switch (dst->op) {
                    case GGML_OP_CONCAT:
                        {
                            const int64_t nb = ne00;

                            [encoder setComputePipelineState:ctx->pipeline_concat];
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];
                            [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:3];
                            [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:4];
                            [encoder setBytes:&ne02 length:sizeof(ne02) atIndex:5];
                            [encoder setBytes:&ne03 length:sizeof(ne03) atIndex:6];
                            [encoder setBytes:&nb00 length:sizeof(nb00) atIndex:7];
                            [encoder setBytes:&nb01 length:sizeof(nb01) atIndex:8];
                            [encoder setBytes:&nb02 length:sizeof(nb02) atIndex:9];
                            [encoder setBytes:&nb03 length:sizeof(nb03) atIndex:10];
                            [encoder setBytes:&ne10 length:sizeof(ne10) atIndex:11];
                            [encoder setBytes:&ne11 length:sizeof(ne11) atIndex:12];
                            [encoder setBytes:&ne12 length:sizeof(ne12) atIndex:13];
                            [encoder setBytes:&ne13 length:sizeof(ne13) atIndex:14];
                            [encoder setBytes:&nb10 length:sizeof(nb10) atIndex:15];
                            [encoder setBytes:&nb11 length:sizeof(nb11) atIndex:16];
                            [encoder setBytes:&nb12 length:sizeof(nb12) atIndex:17];
                            [encoder setBytes:&nb13 length:sizeof(nb13) atIndex:18];
                            [encoder setBytes:&ne0  length:sizeof(ne0)  atIndex:19];
                            [encoder setBytes:&ne1  length:sizeof(ne1)  atIndex:20];
                            [encoder setBytes:&ne2  length:sizeof(ne2)  atIndex:21];
                            [encoder setBytes:&ne3  length:sizeof(ne3)  atIndex:22];
                            [encoder setBytes:&nb0  length:sizeof(nb0)  atIndex:23];
                            [encoder setBytes:&nb1  length:sizeof(nb1)  atIndex:24];
                            [encoder setBytes:&nb2  length:sizeof(nb2)  atIndex:25];
                            [encoder setBytes:&nb3  length:sizeof(nb3)  atIndex:26];
                            [encoder setBytes:&nb   length:sizeof(nb)   atIndex:27];

                            const int nth = MIN(1024, ne0);

                            [encoder dispatchThreadgroups:MTLSizeMake(ne1, ne2, ne3) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                        } break;
                    case GGML_OP_ADD:
                    case GGML_OP_MUL:
                    case GGML_OP_DIV:
                        {
                            GGML_ASSERT(ggml_is_contiguous(src0));
                            GGML_ASSERT(ggml_is_contiguous(src1));

                            bool bcast_row = false;

                            int64_t nb = ne00;

                            if (ggml_nelements(src1) == ne10 && ne00 % 4 == 0) {
                                // src1 is a row
                                GGML_ASSERT(ne11 == 1);

                                nb = ne00 / 4;
                                switch (dst->op) {
                                    case GGML_OP_ADD: [encoder setComputePipelineState:ctx->pipeline_add_row]; break;
                                    case GGML_OP_MUL: [encoder setComputePipelineState:ctx->pipeline_mul_row]; break;
                                    case GGML_OP_DIV: [encoder setComputePipelineState:ctx->pipeline_div_row]; break;
                                    default: GGML_ASSERT(false);
                                }

                                bcast_row = true;
                            } else {
                                switch (dst->op) {
                                    case GGML_OP_ADD: [encoder setComputePipelineState:ctx->pipeline_add]; break;
                                    case GGML_OP_MUL: [encoder setComputePipelineState:ctx->pipeline_mul]; break;
                                    case GGML_OP_DIV: [encoder setComputePipelineState:ctx->pipeline_div]; break;
                                    default: GGML_ASSERT(false);
                                }
                            }
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];
                            [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:3];
                            [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:4];
                            [encoder setBytes:&ne02 length:sizeof(ne02) atIndex:5];
                            [encoder setBytes:&ne03 length:sizeof(ne03) atIndex:6];
                            [encoder setBytes:&nb00 length:sizeof(nb00) atIndex:7];
                            [encoder setBytes:&nb01 length:sizeof(nb01) atIndex:8];
                            [encoder setBytes:&nb02 length:sizeof(nb02) atIndex:9];
                            [encoder setBytes:&nb03 length:sizeof(nb03) atIndex:10];
                            [encoder setBytes:&ne10 length:sizeof(ne10) atIndex:11];
                            [encoder setBytes:&ne11 length:sizeof(ne11) atIndex:12];
                            [encoder setBytes:&ne12 length:sizeof(ne12) atIndex:13];
                            [encoder setBytes:&ne13 length:sizeof(ne13) atIndex:14];
                            [encoder setBytes:&nb10 length:sizeof(nb10) atIndex:15];
                            [encoder setBytes:&nb11 length:sizeof(nb11) atIndex:16];
                            [encoder setBytes:&nb12 length:sizeof(nb12) atIndex:17];
                            [encoder setBytes:&nb13 length:sizeof(nb13) atIndex:18];
                            [encoder setBytes:&ne0  length:sizeof(ne0)  atIndex:19];
                            [encoder setBytes:&ne1  length:sizeof(ne1)  atIndex:20];
                            [encoder setBytes:&ne2  length:sizeof(ne2)  atIndex:21];
                            [encoder setBytes:&ne3  length:sizeof(ne3)  atIndex:22];
                            [encoder setBytes:&nb0  length:sizeof(nb0)  atIndex:23];
                            [encoder setBytes:&nb1  length:sizeof(nb1)  atIndex:24];
                            [encoder setBytes:&nb2  length:sizeof(nb2)  atIndex:25];
                            [encoder setBytes:&nb3  length:sizeof(nb3)  atIndex:26];
                            [encoder setBytes:&nb   length:sizeof(nb)   atIndex:27];

                            if (bcast_row) {
                                const int64_t n = ggml_nelements(dst)/4;

                                [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                            } else {
                                const int nth = MIN(1024, ne0);

                                [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                            }
                        } break;
                    case GGML_OP_SCALE:
                        {
                            GGML_ASSERT(ggml_is_contiguous(src0));

                            const float scale = *(const float *) src1->data;

                            int64_t n = ggml_nelements(dst);

                            if (n % 4 == 0) {
                                n /= 4;
                                [encoder setComputePipelineState:ctx->pipeline_scale_4];
                            } else {
                                [encoder setComputePipelineState:ctx->pipeline_scale];
                            }

                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                            [encoder setBytes:&scale length:sizeof(scale) atIndex:2];

                            [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        } break;
                    case GGML_OP_UNARY:
                        switch (ggml_get_unary_op(gf->nodes[i])) {
                            case GGML_UNARY_OP_SILU:
                                {
                                    [encoder setComputePipelineState:ctx->pipeline_silu];
                                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];

                                    const int64_t n = ggml_nelements(dst);
                                    GGML_ASSERT(n % 4 == 0);

                                    [encoder dispatchThreadgroups:MTLSizeMake(n/4, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                                } break;
                            case GGML_UNARY_OP_RELU:
                                {
                                    [encoder setComputePipelineState:ctx->pipeline_relu];
                                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];

                                    const int64_t n = ggml_nelements(dst);

                                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                                } break;
                            case GGML_UNARY_OP_GELU:
                                {
                                    [encoder setComputePipelineState:ctx->pipeline_gelu];
                                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];

                                    const int64_t n = ggml_nelements(dst);
                                    GGML_ASSERT(n % 4 == 0);

                                    [encoder dispatchThreadgroups:MTLSizeMake(n/4, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                                } break;
                            default:
                                {
                                    GGML_METAL_LOG_WARN("%s: node %3d, op = %8s not implemented\n", __func__, i, ggml_op_name(dst->op));
                                    GGML_ASSERT(false);
                                }
                        } break;
                    case GGML_OP_SQR:
                        {
                            GGML_ASSERT(ggml_is_contiguous(src0));

                            [encoder setComputePipelineState:ctx->pipeline_sqr];
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst atIndex:1];

                            const int64_t n = ggml_nelements(dst);
                            [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        } break;
                    case GGML_OP_SUM_ROWS:
                        {
                            GGML_ASSERT(src0->nb[0] == ggml_type_size(src0->type));

                            [encoder setComputePipelineState:ctx->pipeline_sum_rows];
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                            [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:2];
                            [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:3];
                            [encoder setBytes:&ne02 length:sizeof(ne02) atIndex:4];
                            [encoder setBytes:&ne03 length:sizeof(ne03) atIndex:5];
                            [encoder setBytes:&nb00 length:sizeof(nb00) atIndex:6];
                            [encoder setBytes:&nb01 length:sizeof(nb01) atIndex:7];
                            [encoder setBytes:&nb02 length:sizeof(nb02) atIndex:8];
                            [encoder setBytes:&nb03 length:sizeof(nb03) atIndex:9];
                            [encoder setBytes:&ne10 length:sizeof(ne10) atIndex:10];
                            [encoder setBytes:&ne11 length:sizeof(ne11) atIndex:11];
                            [encoder setBytes:&ne12 length:sizeof(ne12) atIndex:12];
                            [encoder setBytes:&ne13 length:sizeof(ne13) atIndex:13];
                            [encoder setBytes:&nb10 length:sizeof(nb10) atIndex:14];
                            [encoder setBytes:&nb11 length:sizeof(nb11) atIndex:15];
                            [encoder setBytes:&nb12 length:sizeof(nb12) atIndex:16];
                            [encoder setBytes:&nb13 length:sizeof(nb13) atIndex:17];
                            [encoder setBytes:&ne0  length:sizeof(ne0)  atIndex:18];
                            [encoder setBytes:&ne1  length:sizeof(ne1)  atIndex:19];
                            [encoder setBytes:&ne2  length:sizeof(ne2)  atIndex:20];
                            [encoder setBytes:&ne3  length:sizeof(ne3)  atIndex:21];
                            [encoder setBytes:&nb0  length:sizeof(nb0)  atIndex:22];
                            [encoder setBytes:&nb1  length:sizeof(nb1)  atIndex:23];
                            [encoder setBytes:&nb2  length:sizeof(nb2)  atIndex:24];
                            [encoder setBytes:&nb3  length:sizeof(nb3)  atIndex:25];

                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        } break;
                    case GGML_OP_SOFT_MAX:
                        {
                            int nth = 32; // SIMD width

                            if (ne00%4 == 0) {
                                [encoder setComputePipelineState:ctx->pipeline_soft_max_4];
                            } else {
                                do {
                                    nth *= 2;
                                } while (nth <= ne00 && nth <= 1024);
                                nth /= 2;
                                [encoder setComputePipelineState:ctx->pipeline_soft_max];
                            }
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                            [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:2];
                            [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:3];
                            [encoder setBytes:&ne02 length:sizeof(ne02) atIndex:4];
                            [encoder setThreadgroupMemoryLength:GGML_PAD(nth/32*sizeof(float), 16) atIndex:0];

                            [encoder dispatchThreadgroups:MTLSizeMake(ne01*ne02*ne03, 1, 1) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                        } break;
                    case GGML_OP_DIAG_MASK_INF:
                        {
                            const int n_past = ((int32_t *)(dst->op_params))[0];

                            if (ne00%8 == 0) {
                                [encoder setComputePipelineState:ctx->pipeline_diag_mask_inf_8];
                            } else {
                                [encoder setComputePipelineState:ctx->pipeline_diag_mask_inf];
                            }
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                            [encoder setBytes:&ne00   length:sizeof(ne00) atIndex:2];
                            [encoder setBytes:&ne01   length:sizeof(ne01) atIndex:3];
                            [encoder setBytes:&n_past length:sizeof(int)  atIndex:4];

                            if (ne00%8 == 0) {
                                [encoder dispatchThreadgroups:MTLSizeMake(ne00*ne01*ne02/8, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                            }
                            else {
                                [encoder dispatchThreadgroups:MTLSizeMake(ne00, ne01, ne02) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                            }
                        } break;
                    case GGML_OP_MUL_MAT:
                        {
                            GGML_ASSERT(ne00 == ne10);
                            GGML_ASSERT(ne03 == ne13);

                            const uint gqa = ne12/ne02;

                            // find the break-even point where the matrix-matrix kernel becomes more efficient compared
                            // to the matrix-vector kernel
                            int ne11_mm_min = 1;

#if 0
                            // the numbers below are measured on M2 Ultra for 7B and 13B models
                            // these numbers do not translate to other devices or model sizes
                            // TODO: need to find a better approach
                            if ([ctx->device.name isEqualToString:@"Apple M2 Ultra"]) {
                                switch (src0t) {
                                    case GGML_TYPE_F16:  ne11_mm_min = 2;  break;
                                    case GGML_TYPE_Q8_0: ne11_mm_min = 7;  break;
                                    case GGML_TYPE_Q2_K: ne11_mm_min = 15; break;
                                    case GGML_TYPE_Q3_K: ne11_mm_min = 7;  break;
                                    case GGML_TYPE_Q4_0:
                                    case GGML_TYPE_Q4_1: ne11_mm_min = 15; break;
                                    case GGML_TYPE_Q4_K: ne11_mm_min = 11; break;
                                    case GGML_TYPE_Q5_0:                          // not tested yet
                                    case GGML_TYPE_Q5_1: ne11_mm_min = 13; break; // not tested yet
                                    case GGML_TYPE_Q5_K: ne11_mm_min = 7;  break;
                                    case GGML_TYPE_Q6_K: ne11_mm_min = 7;  break;
                                    default:             ne11_mm_min = 1;  break;
                                }
                            }
#endif

                            // for now the matrix-matrix multiplication kernel only works on A14+/M1+ SoCs
                            // AMD GPU and older A-chips will reuse matrix-vector multiplication kernel
                            if ([ctx->device supportsFamily:MTLGPUFamilyApple7] &&
                                !ggml_is_transposed(src0) &&
                                !ggml_is_transposed(src1) &&
                                src1t == GGML_TYPE_F32 &&
                                ne00 % 32 == 0 && ne00 >= 64 &&
                                ne11 > ne11_mm_min) {
                                //printf("matrix: ne00 = %6d, ne01 = %6d, ne02 = %6d, ne11 = %6d, ne12 = %6d\n", ne00, ne01, ne02, ne11, ne12);
                                switch (src0->type) {
                                    case GGML_TYPE_F32:  [encoder setComputePipelineState:ctx->pipeline_mul_mm_f32_f32];  break;
                                    case GGML_TYPE_F16:  [encoder setComputePipelineState:ctx->pipeline_mul_mm_f16_f32];  break;
                                    case GGML_TYPE_Q4_0: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q4_0_f32]; break;
                                    case GGML_TYPE_Q4_1: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q4_1_f32]; break;
                                    case GGML_TYPE_Q5_0: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q5_0_f32]; break;
                                    case GGML_TYPE_Q5_1: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q5_1_f32]; break;
                                    case GGML_TYPE_Q8_0: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q8_0_f32]; break;
                                    case GGML_TYPE_Q2_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q2_K_f32]; break;
                                    case GGML_TYPE_Q3_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q3_K_f32]; break;
                                    case GGML_TYPE_Q4_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q4_K_f32]; break;
                                    case GGML_TYPE_Q5_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q5_K_f32]; break;
                                    case GGML_TYPE_Q6_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_q6_K_f32]; break;
                                    default: GGML_ASSERT(false && "MUL MAT-MAT not implemented");
                                }
                                [encoder setBuffer:id_src0 offset:offs_src0    atIndex:0];
                                [encoder setBuffer:id_src1 offset:offs_src1    atIndex:1];
                                [encoder setBuffer:id_dst  offset:offs_dst     atIndex:2];
                                [encoder setBytes:&ne00    length:sizeof(ne00) atIndex:3];
                                [encoder setBytes:&ne02    length:sizeof(ne02) atIndex:4];
                                [encoder setBytes:&nb01    length:sizeof(nb01) atIndex:5];
                                [encoder setBytes:&nb02    length:sizeof(nb02) atIndex:6];
                                [encoder setBytes:&ne12    length:sizeof(ne12) atIndex:7];
                                [encoder setBytes:&nb10    length:sizeof(nb10) atIndex:8];
                                [encoder setBytes:&nb11    length:sizeof(nb11) atIndex:9];
                                [encoder setBytes:&nb12    length:sizeof(nb12) atIndex:10];
                                [encoder setBytes:&ne0     length:sizeof(ne0)  atIndex:11];
                                [encoder setBytes:&ne1     length:sizeof(ne1)  atIndex:12];
                                [encoder setBytes:&gqa     length:sizeof(gqa)  atIndex:13];
                                [encoder setThreadgroupMemoryLength:8192 atIndex:0];
                                [encoder dispatchThreadgroups:MTLSizeMake( (ne11 + 31)/32, (ne01 + 63)/64, ne12) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
                            } else {
                                int nth0 = 32;
                                int nth1 = 1;
                                int nrows = 1;
                                //printf("vector: ne00 = %6d, ne01 = %6d, ne02 = %6d, ne11 = %6d, ne12 = %6d\n", ne00, ne01, ne02, ne11, ne12);

                                // use custom matrix x vector kernel
                                switch (src0t) {
                                    case GGML_TYPE_F32:
                                        {
                                            GGML_ASSERT(src1t == GGML_TYPE_F32);
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_f32_f32];
                                            nrows = 4;
                                        } break;
                                    case GGML_TYPE_F16:
                                        {
                                            nth0 = 32;
                                            nth1 = 1;
                                            if (src1t == GGML_TYPE_F32) {
                                                if (ne11 * ne12 < 4) {
                                                    [encoder setComputePipelineState:ctx->pipeline_mul_mv_f16_f32_1row];
                                                } else if (ne00 >= 128 && ne01 >= 8 && ne00%4 == 0) {
                                                    [encoder setComputePipelineState:ctx->pipeline_mul_mv_f16_f32_l4];
                                                    nrows = ne11;
                                                } else {
                                                    [encoder setComputePipelineState:ctx->pipeline_mul_mv_f16_f32];
                                                    nrows = 4;
                                                }
                                            } else {
                                                [encoder setComputePipelineState:ctx->pipeline_mul_mv_f16_f16];
                                                nrows = 4;
                                            }
                                        } break;
                                    case GGML_TYPE_Q4_0:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 8;
                                            nth1 = 8;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q4_0_f32];
                                        } break;
                                    case GGML_TYPE_Q4_1:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 8;
                                            nth1 = 8;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q4_1_f32];
                                        } break;
                                    case GGML_TYPE_Q5_0:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 8;
                                            nth1 = 8;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q5_0_f32];
                                        } break;
                                    case GGML_TYPE_Q5_1:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 8;
                                            nth1 = 8;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q5_1_f32];
                                        } break;
                                    case GGML_TYPE_Q8_0:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 8;
                                            nth1 = 8;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q8_0_f32];
                                        } break;
                                    case GGML_TYPE_Q2_K:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 2;
                                            nth1 = 32;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q2_K_f32];
                                        } break;
                                    case GGML_TYPE_Q3_K:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 2;
                                            nth1 = 32;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q3_K_f32];
                                        } break;
                                    case GGML_TYPE_Q4_K:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 4; //1;
                                            nth1 = 8; //32;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q4_K_f32];
                                        } break;
                                    case GGML_TYPE_Q5_K:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 2;
                                            nth1 = 32;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q5_K_f32];
                                        } break;
                                    case GGML_TYPE_Q6_K:
                                        {
                                            GGML_ASSERT(ne02 == 1);
                                            GGML_ASSERT(ne12 == 1);

                                            nth0 = 2;
                                            nth1 = 32;
                                            [encoder setComputePipelineState:ctx->pipeline_mul_mv_q6_K_f32];
                                        } break;
                                    default:
                                        {
                                            GGML_METAL_LOG_ERROR("Asserting on type %d\n", (int)src0t);
                                            GGML_ASSERT(false && "not implemented");
                                        }
                                };

                                [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                                [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                                [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];
                                [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:3];
                                [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:4];
                                [encoder setBytes:&ne02 length:sizeof(ne02) atIndex:5];
                                [encoder setBytes:&nb00 length:sizeof(nb00) atIndex:6];
                                [encoder setBytes:&nb01 length:sizeof(nb01) atIndex:7];
                                [encoder setBytes:&nb02 length:sizeof(nb02) atIndex:8];
                                [encoder setBytes:&ne10 length:sizeof(ne10) atIndex:9];
                                [encoder setBytes:&ne11 length:sizeof(ne11) atIndex:10];
                                [encoder setBytes:&ne12 length:sizeof(ne12) atIndex:11];
                                [encoder setBytes:&nb10 length:sizeof(nb10) atIndex:12];
                                [encoder setBytes:&nb11 length:sizeof(nb11) atIndex:13];
                                [encoder setBytes:&nb12 length:sizeof(nb12) atIndex:14];
                                [encoder setBytes:&ne0  length:sizeof(ne0)  atIndex:15];
                                [encoder setBytes:&ne1  length:sizeof(ne1)  atIndex:16];
                                [encoder setBytes:&gqa  length:sizeof(gqa)  atIndex:17];

                                if (src0t == GGML_TYPE_Q4_0 || src0t == GGML_TYPE_Q4_1 ||
                                    src0t == GGML_TYPE_Q5_0 || src0t == GGML_TYPE_Q5_1 || src0t == GGML_TYPE_Q8_0 ||
                                    src0t == GGML_TYPE_Q2_K) { // || src0t == GGML_TYPE_Q4_K) {
                                    [encoder dispatchThreadgroups:MTLSizeMake((ne01 + 7)/8, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                                }
                                else if (src0t == GGML_TYPE_Q4_K) {
                                    [encoder dispatchThreadgroups:MTLSizeMake((ne01 + 3)/4, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                                }
                                else if (src0t == GGML_TYPE_Q3_K) {
#ifdef GGML_QKK_64
                                    [encoder dispatchThreadgroups:MTLSizeMake((ne01 + 1)/2, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
#else
                                    [encoder dispatchThreadgroups:MTLSizeMake((ne01 + 3)/4, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
#endif
                                }
                                else if (src0t == GGML_TYPE_Q5_K) {
                                    [encoder dispatchThreadgroups:MTLSizeMake((ne01 + 3)/4, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                                }
                                else if (src0t == GGML_TYPE_Q6_K) {
                                    [encoder dispatchThreadgroups:MTLSizeMake((ne01 + 1)/2, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                                } else {
                                    int64_t ny = (ne11 + nrows - 1)/nrows;
                                    [encoder dispatchThreadgroups:MTLSizeMake(ne01, ny, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                                }
                            }
                        } break;
                    case GGML_OP_MUL_MAT_ID:
                        {
                            //GGML_ASSERT(ne00 == ne10);
                            //GGML_ASSERT(ne03 == ne13);

                            GGML_ASSERT(src0t == GGML_TYPE_I32);

                            const int n_as = ne00;

                            // TODO: make this more general
                            GGML_ASSERT(n_as <= 8);

                            struct ggml_tensor * src2 = gf->nodes[i]->src[2];

                            const int64_t  ne20 = src2 ? src2->ne[0] : 0;
                            const int64_t  ne21 = src2 ? src2->ne[1] : 0;
                            const int64_t  ne22 = src2 ? src2->ne[2] : 0;
                            const int64_t  ne23 = src2 ? src2->ne[3] : 0; GGML_UNUSED(ne23);

                            const uint64_t nb20 = src2 ? src2->nb[0] : 0; GGML_UNUSED(nb20);
                            const uint64_t nb21 = src2 ? src2->nb[1] : 0;
                            const uint64_t nb22 = src2 ? src2->nb[2] : 0;
                            const uint64_t nb23 = src2 ? src2->nb[3] : 0; GGML_UNUSED(nb23);

                            const enum ggml_type src2t = src2 ? src2->type : GGML_TYPE_COUNT; GGML_UNUSED(src2t);

                            GGML_ASSERT(!ggml_is_transposed(src2));
                            GGML_ASSERT(!ggml_is_transposed(src1));

                            GGML_ASSERT(ne20 % 32 == 0);
                            // !!!!!!!!! TODO: this assert is probably required but not sure!
                            //GGML_ASSERT(ne20 >= 64);
                            GGML_ASSERT(src1t == GGML_TYPE_F32);

                            const uint gqa = ne12/ne22;

                            // find the break-even point where the matrix-matrix kernel becomes more efficient compared
                            // to the matrix-vector kernel
                            int ne11_mm_min = 0;

                            const int idx = ((int32_t *) dst->op_params)[0];

                            // for now the matrix-matrix multiplication kernel only works on A14+/M1+ SoCs
                            // AMD GPU and older A-chips will reuse matrix-vector multiplication kernel
                            if ([ctx->device supportsFamily:MTLGPUFamilyApple7] &&
                                ne11 > ne11_mm_min) {
                                switch (src2->type) {
                                    case GGML_TYPE_F32:  [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_f32_f32];  break;
                                    case GGML_TYPE_F16:  [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_f16_f32];  break;
                                    case GGML_TYPE_Q4_0: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q4_0_f32]; break;
                                    case GGML_TYPE_Q4_1: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q4_1_f32]; break;
                                    case GGML_TYPE_Q5_0: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q5_0_f32]; break;
                                    case GGML_TYPE_Q5_1: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q5_1_f32]; break;
                                    case GGML_TYPE_Q8_0: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q8_0_f32]; break;
                                    case GGML_TYPE_Q2_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q2_K_f32]; break;
                                    case GGML_TYPE_Q3_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q3_K_f32]; break;
                                    case GGML_TYPE_Q4_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q4_K_f32]; break;
                                    case GGML_TYPE_Q5_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q5_K_f32]; break;
                                    case GGML_TYPE_Q6_K: [encoder setComputePipelineState:ctx->pipeline_mul_mm_id_q6_K_f32]; break;
                                    default: GGML_ASSERT(false && "MUL_MAT_ID not implemented");
                                }
                                [encoder setBuffer:id_src0 offset:offs_src0    atIndex:0];
                                [encoder setBuffer:id_src1 offset:offs_src1    atIndex:1];
                                [encoder setBuffer:id_dst  offset:offs_dst     atIndex:2];
                                [encoder setBytes:&ne20    length:sizeof(ne20) atIndex:3];
                                [encoder setBytes:&ne22    length:sizeof(ne22) atIndex:4];
                                [encoder setBytes:&nb21    length:sizeof(nb21) atIndex:5];
                                [encoder setBytes:&nb22    length:sizeof(nb22) atIndex:6];
                                [encoder setBytes:&ne12    length:sizeof(ne12) atIndex:7];
                                [encoder setBytes:&nb10    length:sizeof(nb10) atIndex:8];
                                [encoder setBytes:&nb11    length:sizeof(nb11) atIndex:9];
                                [encoder setBytes:&nb12    length:sizeof(nb12) atIndex:10];
                                [encoder setBytes:&ne0     length:sizeof(ne0)  atIndex:11];
                                [encoder setBytes:&ne1     length:sizeof(ne1)  atIndex:12];
                                [encoder setBytes:&gqa     length:sizeof(gqa)  atIndex:13];
                                [encoder setBytes:&idx     length:sizeof(idx)  atIndex:14];
                                // TODO: how to make this an array? read Metal docs
                                for (int j = 0; j < n_as; ++j) {
                                    struct ggml_tensor * src_cur = dst->src[2 + j];

                                    size_t offs_src_cur = 0;
                                    id<MTLBuffer> id_src_cur = ggml_metal_get_buffer(ctx, src_cur, &offs_src_cur);

                                    [encoder setBuffer:id_src_cur offset:offs_src_cur atIndex:15 + j];
                                }

                                [encoder setThreadgroupMemoryLength:8192 atIndex:0];
                                [encoder dispatchThreadgroups:MTLSizeMake( (ne11 + 31)/32, (ne21 + 63)/64, ne12) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
                            }
                        } break;
                    case GGML_OP_GET_ROWS:
                        {
                            switch (src0->type) {
                                case GGML_TYPE_F32:  [encoder setComputePipelineState:ctx->pipeline_get_rows_f32];  break;
                                case GGML_TYPE_F16:  [encoder setComputePipelineState:ctx->pipeline_get_rows_f16];  break;
                                case GGML_TYPE_Q4_0: [encoder setComputePipelineState:ctx->pipeline_get_rows_q4_0]; break;
                                case GGML_TYPE_Q4_1: [encoder setComputePipelineState:ctx->pipeline_get_rows_q4_1]; break;
                                case GGML_TYPE_Q5_0: [encoder setComputePipelineState:ctx->pipeline_get_rows_q5_0]; break;
                                case GGML_TYPE_Q5_1: [encoder setComputePipelineState:ctx->pipeline_get_rows_q5_1]; break;
                                case GGML_TYPE_Q8_0: [encoder setComputePipelineState:ctx->pipeline_get_rows_q8_0]; break;
                                case GGML_TYPE_Q2_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q2_K]; break;
                                case GGML_TYPE_Q3_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q3_K]; break;
                                case GGML_TYPE_Q4_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q4_K]; break;
                                case GGML_TYPE_Q5_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q5_K]; break;
                                case GGML_TYPE_Q6_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q6_K]; break;
                                default: GGML_ASSERT(false && "not implemented");
                            }

                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];
                            [encoder setBytes:&ne00 length:sizeof( int64_t) atIndex:3];
                            [encoder setBytes:&nb01 length:sizeof(uint64_t) atIndex:4];
                            [encoder setBytes:&nb1  length:sizeof(uint64_t) atIndex:5];

                            const int64_t n = ggml_nelements(src1);

                            [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        } break;
                    case GGML_OP_RMS_NORM:
                        {
                            GGML_ASSERT(ne00 % 4 == 0);

                            float eps;
                            memcpy(&eps, dst->op_params, sizeof(float));

                            const int nth = MIN(512, ne00);

                            [encoder setComputePipelineState:ctx->pipeline_rms_norm];
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                            [encoder setBytes:&ne00 length:sizeof( int64_t) atIndex:2];
                            [encoder setBytes:&nb01 length:sizeof(uint64_t) atIndex:3];
                            [encoder setBytes:&eps  length:sizeof(   float) atIndex:4];
                            [encoder setThreadgroupMemoryLength:GGML_PAD(nth/32*sizeof(float), 16) atIndex:0];

                            const int64_t nrows = ggml_nrows(src0);

                            [encoder dispatchThreadgroups:MTLSizeMake(nrows, 1, 1) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                        } break;
                    case GGML_OP_NORM:
                        {
                            float eps;
                            memcpy(&eps, dst->op_params, sizeof(float));

                            const int nth = MIN(256, ne00);

                            [encoder setComputePipelineState:ctx->pipeline_norm];
                            [encoder setBuffer:id_src0 offset:offs_src0        atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst         atIndex:1];
                            [encoder setBytes:&ne00    length:sizeof( int64_t) atIndex:2];
                            [encoder setBytes:&nb01    length:sizeof(uint64_t) atIndex:3];
                            [encoder setBytes:&eps     length:sizeof(   float) atIndex:4];
                            [encoder setThreadgroupMemoryLength:GGML_PAD(nth*sizeof(float), 16) atIndex:0];

                            const int64_t nrows = ggml_nrows(src0);

                            [encoder dispatchThreadgroups:MTLSizeMake(nrows, 1, 1) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                        } break;
                    case GGML_OP_ALIBI:
                        {
                            GGML_ASSERT((src0t == GGML_TYPE_F32));

                            const int nth = MIN(1024, ne00);

                            //const int n_past = ((int32_t *) dst->op_params)[0];
                            const int n_head = ((int32_t *) dst->op_params)[1];
                            float max_bias;
                            memcpy(&max_bias, (int32_t *) dst->op_params + 2, sizeof(float));

                            const int n_heads_log2_floor = 1 << (int) floor(log2(n_head));
                            const float m0 = powf(2.0f, -(max_bias) / n_heads_log2_floor);
                            const float m1 = powf(2.0f, -(max_bias / 2.0f) / n_heads_log2_floor);

                            [encoder setComputePipelineState:ctx->pipeline_alibi_f32];
                            [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                            [encoder setBytes:&ne00 length:sizeof( int64_t) atIndex:2];
                            [encoder setBytes:&ne01 length:sizeof( int64_t) atIndex:3];
                            [encoder setBytes:&ne02 length:sizeof( int64_t) atIndex:4];
                            [encoder setBytes:&ne03 length:sizeof( int64_t) atIndex:5];
                            [encoder setBytes:&nb00 length:sizeof(uint64_t) atIndex:6];
                            [encoder setBytes:&nb01 length:sizeof(uint64_t) atIndex:7];
                            [encoder setBytes:&nb02 length:sizeof(uint64_t) atIndex:8];
                            [encoder setBytes:&nb03 length:sizeof(uint64_t) atIndex:9];
                            [encoder setBytes:&ne0  length:sizeof( int64_t) atIndex:10];
                            [encoder setBytes:&ne1  length:sizeof( int64_t) atIndex:11];
                            [encoder setBytes:&ne2  length:sizeof( int64_t) atIndex:12];
                            [encoder setBytes:&ne3  length:sizeof( int64_t) atIndex:13];
                            [encoder setBytes:&nb0  length:sizeof(uint64_t) atIndex:14];
                            [encoder setBytes:&nb1  length:sizeof(uint64_t) atIndex:15];
                            [encoder setBytes:&nb2  length:sizeof(uint64_t) atIndex:16];
                            [encoder setBytes:&nb3  length:sizeof(uint64_t) atIndex:17];
                            [encoder setBytes:&m0   length:sizeof(   float) atIndex:18];
                            [encoder setBytes:&m1   length:sizeof(   float) atIndex:19];
                            [encoder setBytes:&n_heads_log2_floor   length:sizeof(int) atIndex:20];

                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                        } break;
                    case GGML_OP_ROPE:
                        {
                            GGML_ASSERT(ne10 == ne02);

                            const int nth = MIN(1024, ne00);

                            const int n_past     = ((int32_t *) dst->op_params)[0];
                            const int n_dims     = ((int32_t *) dst->op_params)[1];
                            const int mode       = ((int32_t *) dst->op_params)[2];
                            const int n_orig_ctx = ((int32_t *) dst->op_params)[3];

                            float freq_base, freq_scale, ext_factor, attn_factor, beta_fast, beta_slow;
                            memcpy(&freq_base,   (int32_t *) dst->op_params +  5, sizeof(float));
                            memcpy(&freq_scale,  (int32_t *) dst->op_params +  6, sizeof(float));
                            memcpy(&ext_factor,  (int32_t *) dst->op_params +  7, sizeof(float));
                            memcpy(&attn_factor, (int32_t *) dst->op_params +  8, sizeof(float));
                            memcpy(&beta_fast,   (int32_t *) dst->op_params +  9, sizeof(float));
                            memcpy(&beta_slow,   (int32_t *) dst->op_params + 10, sizeof(float));

                            switch (src0->type) {
                                case GGML_TYPE_F32: [encoder setComputePipelineState:ctx->pipeline_rope_f32]; break;
                                case GGML_TYPE_F16: [encoder setComputePipelineState:ctx->pipeline_rope_f16]; break;
                                default: GGML_ASSERT(false);
                            };

                            [encoder setBuffer:id_src0     offset:offs_src0        atIndex:0];
                            [encoder setBuffer:id_src1     offset:offs_src1        atIndex:1];
                            [encoder setBuffer:id_dst      offset:offs_dst         atIndex:2];
                            [encoder setBytes:&ne00        length:sizeof( int64_t) atIndex:3];
                            [encoder setBytes:&ne01        length:sizeof( int64_t) atIndex:4];
                            [encoder setBytes:&ne02        length:sizeof( int64_t) atIndex:5];
                            [encoder setBytes:&ne03        length:sizeof( int64_t) atIndex:6];
                            [encoder setBytes:&nb00        length:sizeof(uint64_t) atIndex:7];
                            [encoder setBytes:&nb01        length:sizeof(uint64_t) atIndex:8];
                            [encoder setBytes:&nb02        length:sizeof(uint64_t) atIndex:9];
                            [encoder setBytes:&nb03        length:sizeof(uint64_t) atIndex:10];
                            [encoder setBytes:&ne0         length:sizeof( int64_t) atIndex:11];
                            [encoder setBytes:&ne1         length:sizeof( int64_t) atIndex:12];
                            [encoder setBytes:&ne2         length:sizeof( int64_t) atIndex:13];
                            [encoder setBytes:&ne3         length:sizeof( int64_t) atIndex:14];
                            [encoder setBytes:&nb0         length:sizeof(uint64_t) atIndex:15];
                            [encoder setBytes:&nb1         length:sizeof(uint64_t) atIndex:16];
                            [encoder setBytes:&nb2         length:sizeof(uint64_t) atIndex:17];
                            [encoder setBytes:&nb3         length:sizeof(uint64_t) atIndex:18];
                            [encoder setBytes:&n_past      length:sizeof(     int) atIndex:19];
                            [encoder setBytes:&n_dims      length:sizeof(     int) atIndex:20];
                            [encoder setBytes:&mode        length:sizeof(     int) atIndex:21];
                            [encoder setBytes:&n_orig_ctx  length:sizeof(     int) atIndex:22];
                            [encoder setBytes:&freq_base   length:sizeof(   float) atIndex:23];
                            [encoder setBytes:&freq_scale  length:sizeof(   float) atIndex:24];
                            [encoder setBytes:&ext_factor  length:sizeof(   float) atIndex:25];
                            [encoder setBytes:&attn_factor length:sizeof(   float) atIndex:26];
                            [encoder setBytes:&beta_fast   length:sizeof(   float) atIndex:27];
                            [encoder setBytes:&beta_slow   length:sizeof(   float) atIndex:28];

                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                        } break;
                    case GGML_OP_IM2COL:
                        {
                            GGML_ASSERT(src0->type == GGML_TYPE_F16);
                            GGML_ASSERT(src1->type == GGML_TYPE_F32);
                            GGML_ASSERT( dst->type == GGML_TYPE_F16);

                            const int32_t s0 = ((const int32_t *)(dst->op_params))[0];
                            const int32_t s1 = ((const int32_t *)(dst->op_params))[1];
                            const int32_t p0 = ((const int32_t *)(dst->op_params))[2];
                            const int32_t p1 = ((const int32_t *)(dst->op_params))[3];
                            const int32_t d0 = ((const int32_t *)(dst->op_params))[4];
                            const int32_t d1 = ((const int32_t *)(dst->op_params))[5];
                            const bool is_2D = ((const int32_t *)(dst->op_params))[6] == 1;

                            const int32_t N  = src1->ne[is_2D ? 3 : 2];
                            const int32_t IC = src1->ne[is_2D ? 2 : 1];
                            const int32_t IH = is_2D ? src1->ne[1] : 1;
                            const int32_t IW =         src1->ne[0];

                            const int32_t KH = is_2D ? src0->ne[1] : 1;
                            const int32_t KW =         src0->ne[0];

                            const int32_t OH = is_2D ? dst->ne[2] : 1;
                            const int32_t OW =         dst->ne[1];

                            const int32_t CHW = IC * KH * KW;

                            const int32_t ofs0 = src1->nb[is_2D ? 3 : 2] / 4;
                            const int32_t ofs1 = src1->nb[is_2D ? 2 : 1] / 4;

                            switch (src0->type) {
                                case GGML_TYPE_F32: GGML_ASSERT(false && "not implemented"); break;
                                case GGML_TYPE_F16: [encoder setComputePipelineState:ctx->pipeline_im2col_f16]; break;
                                default: GGML_ASSERT(false);
                            };

                            [encoder setBuffer:id_src1 offset:offs_src1        atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst         atIndex:1];
                            [encoder setBytes:&ofs0    length:sizeof( int32_t) atIndex:2];
                            [encoder setBytes:&ofs1    length:sizeof( int32_t) atIndex:3];
                            [encoder setBytes:&IW      length:sizeof( int32_t) atIndex:4];
                            [encoder setBytes:&IH      length:sizeof( int32_t) atIndex:5];
                            [encoder setBytes:&CHW     length:sizeof( int32_t) atIndex:6];
                            [encoder setBytes:&s0      length:sizeof( int32_t) atIndex:7];
                            [encoder setBytes:&s1      length:sizeof( int32_t) atIndex:8];
                            [encoder setBytes:&p0      length:sizeof( int32_t) atIndex:9];
                            [encoder setBytes:&p1      length:sizeof( int32_t) atIndex:10];
                            [encoder setBytes:&d0      length:sizeof( int32_t) atIndex:11];
                            [encoder setBytes:&d1      length:sizeof( int32_t) atIndex:12];

                            [encoder dispatchThreadgroups:MTLSizeMake(IC, OH, OW) threadsPerThreadgroup:MTLSizeMake(N, KH, KW)];
                        } break;
                    case GGML_OP_ARGSORT:
                        {
                            GGML_ASSERT(src0->type == GGML_TYPE_F32);
                            GGML_ASSERT( dst->type == GGML_TYPE_I32);

                            const int nrows = ggml_nrows(src0);

                            enum ggml_sort_order order = (enum ggml_sort_order) dst->op_params[0];

                            switch (order) {
                                case GGML_SORT_ASC:  [encoder setComputePipelineState:ctx->pipeline_argsort_f32_i32_asc];  break;
                                case GGML_SORT_DESC: [encoder setComputePipelineState:ctx->pipeline_argsort_f32_i32_desc]; break;
                                default: GGML_ASSERT(false);
                            };

                            [encoder setBuffer:id_src0 offset:offs_src0        atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst         atIndex:1];
                            [encoder setBytes:&ne00    length:sizeof( int64_t) atIndex:2];

                            [encoder dispatchThreadgroups:MTLSizeMake(1, nrows, 1) threadsPerThreadgroup:MTLSizeMake(ne00, 1, 1)];
                        } break;
                    case GGML_OP_DUP:
                    case GGML_OP_CPY:
                    case GGML_OP_CONT:
                        {
                            const int nth = MIN(1024, ne00);

                            switch (src0t) {
                                case GGML_TYPE_F32:
                                    {
                                        switch (dstt) {
                                            case GGML_TYPE_F16: [encoder setComputePipelineState:ctx->pipeline_cpy_f32_f16]; break;
                                            case GGML_TYPE_F32: [encoder setComputePipelineState:ctx->pipeline_cpy_f32_f32]; break;
                                            default: GGML_ASSERT(false && "not implemented");
                                        };
                                    } break;
                                case GGML_TYPE_F16:
                                    {
                                        switch (dstt) {
                                            case GGML_TYPE_F16: [encoder setComputePipelineState:ctx->pipeline_cpy_f16_f16]; break;
                                            case GGML_TYPE_F32: GGML_ASSERT(false && "cpy_f16_f32 not implemented"); break;
                                            default: GGML_ASSERT(false && "not implemented");
                                        };
                                    } break;
                                default: GGML_ASSERT(false && "not implemented");
                            }

                            [encoder setBuffer:id_src0 offset:offs_src0        atIndex:0];
                            [encoder setBuffer:id_dst  offset:offs_dst         atIndex:1];
                            [encoder setBytes:&ne00    length:sizeof( int64_t) atIndex:2];
                            [encoder setBytes:&ne01    length:sizeof( int64_t) atIndex:3];
                            [encoder setBytes:&ne02    length:sizeof( int64_t) atIndex:4];
                            [encoder setBytes:&ne03    length:sizeof( int64_t) atIndex:5];
                            [encoder setBytes:&nb00    length:sizeof(uint64_t) atIndex:6];
                            [encoder setBytes:&nb01    length:sizeof(uint64_t) atIndex:7];
                            [encoder setBytes:&nb02    length:sizeof(uint64_t) atIndex:8];
                            [encoder setBytes:&nb03    length:sizeof(uint64_t) atIndex:9];
                            [encoder setBytes:&ne0     length:sizeof( int64_t) atIndex:10];
                            [encoder setBytes:&ne1     length:sizeof( int64_t) atIndex:11];
                            [encoder setBytes:&ne2     length:sizeof( int64_t) atIndex:12];
                            [encoder setBytes:&ne3     length:sizeof( int64_t) atIndex:13];
                            [encoder setBytes:&nb0     length:sizeof(uint64_t) atIndex:14];
                            [encoder setBytes:&nb1     length:sizeof(uint64_t) atIndex:15];
                            [encoder setBytes:&nb2     length:sizeof(uint64_t) atIndex:16];
                            [encoder setBytes:&nb3     length:sizeof(uint64_t) atIndex:17];

                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                        } break;
                    default:
                        {
                            GGML_METAL_LOG_ERROR("%s: error: node %3d, op = %8s not implemented\n", __func__, i, ggml_op_name(dst->op));
                            GGML_ASSERT(false);
                        }
                }
            }

            if (encoder != nil) {
                [encoder endEncoding];
                encoder = nil;
            }

            [command_buffer commit];
        });
    }

    // wait for all threads to finish
    dispatch_barrier_sync(ctx->d_queue, ^{});

    // check status of command buffers
    // needed to detect if the device ran out-of-memory for example (#1881)
    for (int i = 0; i < n_cb; i++) {
        [ctx->command_buffers[i] waitUntilCompleted];

        MTLCommandBufferStatus status = (MTLCommandBufferStatus) [ctx->command_buffers[i] status];
        if (status != MTLCommandBufferStatusCompleted) {
            GGML_METAL_LOG_INFO("%s: command buffer %d failed with status %lu\n", __func__, i, status);
            GGML_ASSERT(false);
        }
    }

    }
}

////////////////////////////////////////////////////////////////////////////////

// backend interface

static id<MTLDevice> g_backend_device = nil;
static int g_backend_device_ref_count = 0;

static id<MTLDevice> ggml_backend_metal_get_device(void) {
    if (g_backend_device == nil) {
        g_backend_device = MTLCreateSystemDefaultDevice();
    }

    g_backend_device_ref_count++;

    return g_backend_device;
}

static void ggml_backend_metal_free_device(void) {
    assert(g_backend_device_ref_count > 0);

    g_backend_device_ref_count--;

    if (g_backend_device_ref_count == 0) {
        [g_backend_device release];
        g_backend_device = nil;
    }
}

static void * ggml_backend_metal_buffer_get_base(ggml_backend_buffer_t buffer) {
    struct ggml_backend_metal_buffer_context * ctx = (struct ggml_backend_metal_buffer_context *)buffer->context;

    return ctx->data;
}

static void ggml_backend_metal_buffer_free_buffer(ggml_backend_buffer_t buffer) {
    struct ggml_backend_metal_buffer_context * ctx = (struct ggml_backend_metal_buffer_context *)buffer->context;

    [ctx->metal release];
    ggml_backend_metal_free_device();

    free(ctx->data);
    free(ctx);

    UNUSED(buffer);
}

static void ggml_backend_metal_buffer_set_tensor(ggml_backend_buffer_t buffer, struct ggml_tensor * tensor, const void * data, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor) && "tensor write out of bounds");
    GGML_ASSERT(tensor->data != NULL && "tensor not allocated");

    memcpy((char *)tensor->data + offset, data, size);

    UNUSED(buffer);
}

static void ggml_backend_metal_buffer_get_tensor(ggml_backend_buffer_t buffer, const struct ggml_tensor * tensor, void * data, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor) && "tensor read out of bounds");
    GGML_ASSERT(tensor->data != NULL && "tensor not allocated");

    memcpy(data, (const char *)tensor->data + offset, size);

    UNUSED(buffer);
}

static void ggml_backend_metal_buffer_cpy_tensor_from(ggml_backend_buffer_t buffer, struct ggml_tensor * src, struct ggml_tensor * dst) {
    ggml_backend_tensor_get(src, dst->data, 0, ggml_nbytes(src));

    UNUSED(buffer);
}

static void ggml_backend_metal_buffer_cpy_tensor_to(ggml_backend_buffer_t buffer, struct ggml_tensor * src, struct ggml_tensor * dst) {
    ggml_backend_tensor_set(dst, src->data, 0, ggml_nbytes(src));

    UNUSED(buffer);
}

static struct ggml_backend_buffer_i metal_backend_buffer_i = {
    /* .free_buffer     = */ ggml_backend_metal_buffer_free_buffer,
    /* .get_base        = */ ggml_backend_metal_buffer_get_base,
    /* .init_tensor     = */ NULL,
    /* .set_tensor      = */ ggml_backend_metal_buffer_set_tensor,
    /* .get_tensor      = */ ggml_backend_metal_buffer_get_tensor,
    /* .cpy_tensor_from = */ ggml_backend_metal_buffer_cpy_tensor_from,
    /* .cpy_tensor_to   = */ ggml_backend_metal_buffer_cpy_tensor_to,
};

static ggml_backend_buffer_t ggml_backend_metal_buffer_type_alloc_buffer(ggml_backend_buffer_type_t buft, size_t size) {
    struct ggml_backend_metal_buffer_context * ctx = malloc(sizeof(struct ggml_backend_metal_buffer_context));

    const size_t size_page = sysconf(_SC_PAGESIZE);

    size_t size_aligned = size;
    if ((size_aligned % size_page) != 0) {
        size_aligned += (size_page - (size_aligned % size_page));
    }

    ctx->data  = ggml_metal_host_malloc(size);
    ctx->metal = [ggml_backend_metal_get_device() newBufferWithBytesNoCopy:ctx->data
                    length:size_aligned
                    options:MTLResourceStorageModeShared
                    deallocator:nil];

    return ggml_backend_buffer_init(buft, metal_backend_buffer_i, ctx, size);
}

static size_t ggml_backend_metal_buffer_type_get_alignment(ggml_backend_buffer_type_t buft) {
    return 32;
    UNUSED(buft);
}

static bool ggml_backend_metal_buffer_type_supports_backend(ggml_backend_buffer_type_t buft, ggml_backend_t backend) {
    return ggml_backend_is_metal(backend) || ggml_backend_is_cpu(backend);

    GGML_UNUSED(buft);
}

ggml_backend_buffer_type_t ggml_backend_metal_buffer_type(void) {
    static struct ggml_backend_buffer_type ggml_backend_buffer_type_metal = {
        /* .iface = */ {
            /* .alloc_buffer     = */ ggml_backend_metal_buffer_type_alloc_buffer,
            /* .get_alignment    = */ ggml_backend_metal_buffer_type_get_alignment,
            /* .get_alloc_size   = */ NULL, // defaults to ggml_nbytes
            /* .supports_backend = */ ggml_backend_metal_buffer_type_supports_backend,
        },
        /* .context = */ NULL,
    };

    return &ggml_backend_buffer_type_metal;
}

static const char * ggml_backend_metal_name(ggml_backend_t backend) {
    return "Metal";

    UNUSED(backend);
}

static void ggml_backend_metal_free(ggml_backend_t backend) {
    struct ggml_metal_context * ctx = (struct ggml_metal_context *)backend->context;
    ggml_metal_free(ctx);
    free(backend);
}

static void ggml_backend_metal_synchronize(ggml_backend_t backend) {
    UNUSED(backend);
}

static ggml_backend_buffer_type_t ggml_backend_metal_get_default_buffer_type(ggml_backend_t backend) {
    return ggml_backend_metal_buffer_type();

    UNUSED(backend);
}

static void ggml_backend_metal_graph_compute(ggml_backend_t backend, struct ggml_cgraph * cgraph) {
    struct ggml_metal_context * metal_ctx = (struct ggml_metal_context *)backend->context;

    ggml_metal_graph_compute(metal_ctx, cgraph);
}

static bool ggml_backend_metal_supports_op(ggml_backend_t backend, const struct ggml_tensor * op) {
    return ggml_metal_supports_op(op);

    UNUSED(backend);
}

static struct ggml_backend_i metal_backend_i = {
    /* .get_name                = */ ggml_backend_metal_name,
    /* .free                    = */ ggml_backend_metal_free,
    /* .get_default_buffer_type = */ ggml_backend_metal_get_default_buffer_type,
    /* .set_tensor_async        = */ NULL,
    /* .get_tensor_async        = */ NULL,
    /* .cpy_tensor_from_async   = */ NULL,
    /* .cpy_tensor_to_async     = */ NULL,
    /* .synchronize             = */ ggml_backend_metal_synchronize,
    /* .graph_plan_create       = */ NULL, // the metal implementation does not require creating graph plans atm
    /* .graph_plan_free         = */ NULL,
    /* .graph_plan_compute      = */ NULL,
    /* .graph_compute           = */ ggml_backend_metal_graph_compute,
    /* .supports_op             = */ ggml_backend_metal_supports_op,
};

// TODO: make a common log callback for all backends in ggml-backend
static void ggml_backend_log_callback(enum ggml_log_level level, const char * msg, void * user_data) {
    fprintf(stderr, "%s", msg);

    UNUSED(level);
    UNUSED(user_data);
}

ggml_backend_t ggml_backend_metal_init(void) {
    ggml_metal_log_set_callback(ggml_backend_log_callback, NULL);

    struct ggml_metal_context * ctx = ggml_metal_init(GGML_DEFAULT_N_THREADS);

    if (ctx == NULL) {
        return NULL;
    }

    ggml_backend_t metal_backend = malloc(sizeof(struct ggml_backend));

    *metal_backend = (struct ggml_backend) {
        /* .interface = */ metal_backend_i,
        /* .context   = */ ctx,
    };

    return metal_backend;
}

bool ggml_backend_is_metal(ggml_backend_t backend) {
    return backend->iface.get_name == ggml_backend_metal_name;
}

void ggml_backend_metal_set_n_cb(ggml_backend_t backend, int n_cb) {
    GGML_ASSERT(ggml_backend_is_metal(backend));

    struct ggml_metal_context * ctx = (struct ggml_metal_context *)backend->context;

    ggml_metal_set_n_cb(ctx, n_cb);
}

static ggml_backend_t ggml_backend_reg_metal_init(const char * params, void * user_data) {
    return ggml_backend_metal_init();

    GGML_UNUSED(params);
    GGML_UNUSED(user_data);
}

GGML_BACKEND_REGISTER("Metal", ggml_backend_reg_metal_init, ggml_backend_metal_buffer_type(), NULL)
