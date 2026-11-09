/*
 * monitor_sender - native version of scripts/sender.sh
 *
 *   videotestsrc -> videobalance -> overlays -> tee -+-> A: preview (window or fakesink)
 *                                                    +-> B: H.264 recording (mkv / ts)
 *                                                    +-> C: RTP/UDP (H.264 or JPEG)
 *
 * The pipeline is built with gst_parse_launch() (option B). Elements that we
 * control at runtime (video_balance, names_overlay) are found by their name.
 *
 * Example:
 *   ./build/monitor_sender --pattern smpte --width 800 --height 450 --fps 10 \
 *       --port 5123 --output artifacts/test-recording.mkv --duration 15 --headless
 */

#include <gst/gst.h>
#include <glib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* exit codes */
#define EXIT_OK        0
#define EXIT_RUNTIME   1   /* pipeline error, EOS timeout, ... */
#define EXIT_USAGE     2   /* bad command line */

#define DYNAMIC_PERIOD_SECONDS   5
#define EOS_TIMEOUT_SECONDS     10   /* max wait between "EOS sent" and "EOS received" */

/* ------------------------------------------------------------------ options */

typedef struct {
    gchar   *pattern;
    gint     width;
    gint     height;
    gint     fps;
    gint     port;
    gchar   *output;
    gint     duration;
    gboolean headless;
    gchar   *host;
    gchar   *codec;
    gchar   *overlay_position;
    gchar   *names;
    gint     bitrate;
} Options;

/* state shared by the callbacks */
typedef struct {
    GstElement *pipeline;
    GstElement *video_balance;
    GMainLoop  *loop;
    Options    *options;
    gboolean    eos_sent;
    gboolean    eos_received;
    gboolean    error_happened;
    guint       dynamic_step;
    guint       dynamic_timer_id;
    guint       duration_timer_id;
    guint       eos_timeout_id;
    guint       interrupt_timer_id;
} AppState;

static const gchar *SUPPORTED_PATTERNS[] = { "smpte", "ball", "snow", "zone-plate", NULL };

/* set from the SIGINT handler, checked from the main loop (we must not call
 * GStreamer functions inside a signal handler) */
static volatile sig_atomic_t interrupt_requested = 0;

static void on_sigint(int signum)
{
    (void) signum;
    interrupt_requested = 1;
}

static gboolean string_in_list(const gchar *value, const gchar **list)
{
    for (int i = 0; list[i] != NULL; i++) {
        if (g_strcmp0(value, list[i]) == 0)
            return TRUE;
    }
    return FALSE;
}

static gboolean check_range(const gchar *name, gint value, gint min, gint max)
{
    if (value == -1) {
        g_printerr("ERROR: missing required option --%s\n", name);
        return FALSE;
    }
    if (value < min || value > max) {
        g_printerr("ERROR: --%s must be between %d and %d (got %d)\n", name, min, max, value);
        return FALSE;
    }
    return TRUE;
}

/* returns the muxer for the extension of the output file, or NULL */
static const gchar *muxer_for_output(const gchar *output)
{
    if (g_str_has_suffix(output, ".mkv"))
        return "matroskamux";
    if (g_str_has_suffix(output, ".ts"))
        return "mpegtsmux";
    return NULL;
}

static gboolean parse_options(int argc, char *argv[], Options *opt)
{
    GError *error = NULL;
    gboolean ok = TRUE;

    /* -1 / NULL = "not given", so we can detect missing required options */
    opt->width = opt->height = opt->fps = opt->port = -1;
    opt->duration = 0;
    opt->bitrate = 1000;

    GOptionEntry entries[] = {
        { "pattern",  0, 0, G_OPTION_ARG_STRING, &opt->pattern,  "Test pattern: smpte, ball, snow, zone-plate (required)", "NAME" },
        { "width",    0, 0, G_OPTION_ARG_INT,    &opt->width,    "Video width in pixels, 16-3840 (required)", "PX" },
        { "height",   0, 0, G_OPTION_ARG_INT,    &opt->height,   "Video height in pixels, 16-2160 (required)", "PX" },
        { "fps",      0, 0, G_OPTION_ARG_INT,    &opt->fps,      "Frame rate, 1-60 (required)", "N" },
        { "port",     0, 0, G_OPTION_ARG_INT,    &opt->port,     "RTP/UDP destination port, 1024-65535 (required)", "PORT" },
        { "output",   0, 0, G_OPTION_ARG_STRING, &opt->output,   "Recording file, .mkv (Matroska) or .ts (MPEG-TS) (required)", "FILE" },
        { "duration", 0, 0, G_OPTION_ARG_INT,    &opt->duration, "Stop cleanly (EOS) after SECONDS, 0 = until Ctrl+C (default 0)", "SECONDS" },
        { "headless", 0, 0, G_OPTION_ARG_NONE,   &opt->headless, "Preview goes to a fakesink instead of a window", NULL },
        { "host",     0, 0, G_OPTION_ARG_STRING, &opt->host,     "RTP destination host (default 127.0.0.1)", "HOST" },
        { "codec",    0, 0, G_OPTION_ARG_STRING, &opt->codec,    "Network codec: h264 or jpeg (default h264)", "CODEC" },
        { "overlay-position", 0, 0, G_OPTION_ARG_STRING, &opt->overlay_position,
          "Position of the names: top-left, top-center, bottom-right (default top-center)", "POS" },
        { "names",    0, 0, G_OPTION_ARG_STRING, &opt->names,    "Team member names shown on the video", "TEXT" },
        { "bitrate",  0, 0, G_OPTION_ARG_INT,    &opt->bitrate,  "H.264 network bitrate in kbit/s, 100-20000 (default 1000)", "KBPS" },
        { NULL }
    };

    GOptionContext *context = g_option_context_new("- video monitoring sender (preview + recording + RTP/UDP)");
    g_option_context_add_main_entries(context, entries, NULL);
    g_option_context_set_summary(context,
        "Generates a test video with overlays and sends it at the same time to a\n"
        "preview, a recording file and an RTP/UDP stream.");
    g_option_context_set_description(context,
        "Example:\n"
        "  monitor_sender --pattern smpte --width 800 --height 450 --fps 10 \\\n"
        "      --port 5123 --output artifacts/test-recording.mkv --duration 15 --headless\n");
    /* GStreamer's own options (--gst-debug-level, ...) */
    g_option_context_add_group(context, gst_init_get_option_group());

    if (!g_option_context_parse(context, &argc, &argv, &error)) {
        /* e.g. "Cannot parse integer value 'abc' for --width" */
        g_printerr("ERROR: %s\n", error->message);
        g_printerr("Run '%s --help' to see the options.\n", argv[0]);
        g_clear_error(&error);
        g_option_context_free(context);
        return FALSE;
    }
    g_option_context_free(context);

    if (argc > 1) {
        g_printerr("ERROR: unexpected argument '%s'\n", argv[1]);
        return FALSE;
    }

    /* defaults for the optional strings */
    if (opt->host == NULL)             opt->host = g_strdup("127.0.0.1");
    if (opt->codec == NULL)            opt->codec = g_strdup("h264");
    if (opt->overlay_position == NULL) opt->overlay_position = g_strdup("top-center");
    if (opt->names == NULL)            opt->names = g_strdup("Nikola MILOSAVLJEVIC, Chenyi LI, Amirhossein POUYANFAR");

    /* check everything, report all problems at once */
    if (opt->pattern == NULL) {
        g_printerr("ERROR: missing required option --pattern\n");
        ok = FALSE;
    } else if (!string_in_list(opt->pattern, SUPPORTED_PATTERNS)) {
        g_printerr("ERROR: unsupported pattern '%s' (use smpte, ball, snow or zone-plate)\n", opt->pattern);
        ok = FALSE;
    }
    ok &= check_range("width", opt->width, 16, 3840);
    ok &= check_range("height", opt->height, 16, 2160);
    ok &= check_range("fps", opt->fps, 1, 60);
    ok &= check_range("port", opt->port, 1024, 65535);
    if (opt->width > 0 && opt->width % 2 != 0) {
        g_printerr("ERROR: --width must be even (I420 / H.264)\n");
        ok = FALSE;
    }
    if (opt->height > 0 && opt->height % 2 != 0) {
        g_printerr("ERROR: --height must be even (I420 / H.264)\n");
        ok = FALSE;
    }
    if (opt->output == NULL) {
        g_printerr("ERROR: missing required option --output\n");
        ok = FALSE;
    } else if (muxer_for_output(opt->output) == NULL) {
        g_printerr("ERROR: unsupported output format '%s' (use a .mkv or .ts file)\n", opt->output);
        ok = FALSE;
    }
    if (opt->duration < 0 || opt->duration > 24 * 3600) {
        g_printerr("ERROR: --duration must be between 0 and 86400 (got %d)\n", opt->duration);
        ok = FALSE;
    }
    if (opt->bitrate < 100 || opt->bitrate > 20000) {
        g_printerr("ERROR: --bitrate must be between 100 and 20000 (got %d)\n", opt->bitrate);
        ok = FALSE;
    }
    if (g_strcmp0(opt->codec, "h264") != 0 && g_strcmp0(opt->codec, "jpeg") != 0) {
        g_printerr("ERROR: unsupported codec '%s' (use h264 or jpeg)\n", opt->codec);
        ok = FALSE;
    }
    if (g_strcmp0(opt->overlay_position, "top-left") != 0 &&
        g_strcmp0(opt->overlay_position, "top-center") != 0 &&
        g_strcmp0(opt->overlay_position, "bottom-right") != 0) {
        g_printerr("ERROR: unsupported overlay position '%s'\n", opt->overlay_position);
        ok = FALSE;
    }
    /* the values are put inside "..." in the gst_parse_launch description */
    if (strchr(opt->names, '"') != NULL || (opt->output && strchr(opt->output, '"') != NULL)) {
        g_printerr("ERROR: --names and --output must not contain '\"'\n");
        ok = FALSE;
    }

    if (!ok)
        g_printerr("Run '%s --help' to see the options.\n", argv[0]);
    return ok;
}

static void free_options(Options *opt)
{
    g_free(opt->pattern);
    g_free(opt->output);
    g_free(opt->host);
    g_free(opt->codec);
    g_free(opt->overlay_position);
    g_free(opt->names);
}

/* ------------------------------------------------------------------ pipeline */

static gchar *build_pipeline_description(const Options *opt)
{
    const gchar *names_valign, *names_halign, *info_valign;

    if (g_strcmp0(opt->overlay_position, "top-left") == 0) {
        names_valign = "top"; names_halign = "left"; info_valign = "bottom";
    } else if (g_strcmp0(opt->overlay_position, "bottom-right") == 0) {
        names_valign = "bottom"; names_halign = "right"; info_valign = "top";
    } else {
        names_valign = "top"; names_halign = "center"; info_valign = "bottom";
    }

    const gchar *preview_sink = opt->headless
        ? "fakesink name=preview_sink sync=true"
        : "autovideosink name=preview_sink sync=true";

    gchar *network_encode;
    if (g_strcmp0(opt->codec, "jpeg") == 0) {
        network_encode = g_strdup(
            "jpegenc name=network_encoder quality=80 ! rtpjpegpay name=network_payloader pt=26");
    } else {
        network_encode = g_strdup_printf(
            "x264enc name=network_encoder speed-preset=ultrafast tune=zerolatency bitrate=%d key-int-max=%d "
            "! video/x-h264,profile=baseline "
            "! rtph264pay name=network_payloader pt=96 config-interval=1",
            opt->bitrate, opt->fps);
    }

    gchar *description = g_strdup_printf(
        /* common part */
        "videotestsrc name=video_source is-live=true pattern=%s "
        "! video/x-raw,width=%d,height=%d,framerate=%d/1 "
        "! videoconvert name=source_convert "
        "! videobalance name=video_balance "
        "! textoverlay name=names_overlay text=\"%s\" valignment=%s halignment=%s "
        "  font-desc=\"Sans 14\" shaded-background=true "
        "! timeoverlay name=time_overlay time-mode=running-time text=\"%dx%d @ %d fps | elapsed\" "
        "  valignment=%s halignment=left font-desc=\"Sans 12\" shaded-background=true "
        "! videoconvert ! video/x-raw,format=I420,width=%d,height=%d,framerate=%d/1 "
        "! tee name=split "
        /* A: preview */
        "split. ! queue name=preview_queue max-size-buffers=5 max-size-time=0 max-size-bytes=0 leaky=downstream "
        "! videoconvert name=preview_convert ! %s "
        /* B: recording */
        "split. ! queue name=record_queue max-size-time=3000000000 max-size-buffers=0 max-size-bytes=0 "
        "! x264enc name=record_encoder speed-preset=ultrafast tune=zerolatency key-int-max=%d "
        "! h264parse name=record_parser ! %s name=record_muxer "
        "! filesink name=record_sink location=\"%s\" "
        /* C: network */
        "split. ! queue name=network_queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 leaky=downstream "
        "! %s "
        "! udpsink name=network_sink host=%s port=%d sync=true",
        opt->pattern, opt->width, opt->height, opt->fps,
        opt->names, names_valign, names_halign,
        opt->width, opt->height, opt->fps, info_valign,
        opt->width, opt->height, opt->fps,
        preview_sink,
        opt->fps * 2, muxer_for_output(opt->output), opt->output,
        network_encode, opt->host, opt->port);

    g_free(network_encode);
    return description;
}

/* ------------------------------------------------------------------ runtime */

static gboolean on_eos_timeout(gpointer user_data)
{
    AppState *app = user_data;
    g_printerr("ERROR: EOS was sent %d s ago but never reached the end of the pipeline, "
               "stopping anyway (recording may be incomplete)\n", EOS_TIMEOUT_SECONDS);
    app->error_happened = TRUE;
    app->eos_timeout_id = 0;
    g_main_loop_quit(app->loop);
    return G_SOURCE_REMOVE;
}

/* sends EOS from the source side; the muxer finalizes the file when it receives it */
static void request_stop(AppState *app, const gchar *reason)
{
    if (app->eos_sent)
        return;
    app->eos_sent = TRUE;
    g_print("STOP_REQUESTED reason=%s -> sending EOS\n", reason);
    gst_element_send_event(app->pipeline, gst_event_new_eos());
    app->eos_timeout_id = g_timeout_add_seconds(EOS_TIMEOUT_SECONDS, on_eos_timeout, app);
}

static gboolean on_duration_elapsed(gpointer user_data)
{
    AppState *app = user_data;
    app->duration_timer_id = 0;
    request_stop(app, "duration");
    return G_SOURCE_REMOVE;
}

static gboolean check_interrupt(gpointer user_data)
{
    AppState *app = user_data;
    if (interrupt_requested) {
        interrupt_requested = 0;
        if (app->eos_sent) {
            g_printerr("second interrupt, quitting without waiting for EOS\n");
            app->error_happened = TRUE;
            g_main_loop_quit(app->loop);
        } else {
            request_stop(app, "interrupt");
        }
    }
    return G_SOURCE_CONTINUE;
}

/* dynamic property: brightness of video_balance changes every 5 seconds */
static gboolean change_dynamic_property(gpointer user_data)
{
    static const gdouble BRIGHTNESS_STEPS[] = { 0.20, 0.0, -0.20, 0.0 };
    AppState *app = user_data;

    if (app->eos_sent)
        return G_SOURCE_CONTINUE;

    gdouble value = BRIGHTNESS_STEPS[app->dynamic_step % G_N_ELEMENTS(BRIGHTNESS_STEPS)];
    app->dynamic_step++;
    g_object_set(app->video_balance, "brightness", value, NULL);

    /* read it back so the log shows the real value of the element */
    gdouble current = 0.0;
    g_object_get(app->video_balance, "brightness", &current, NULL);
    g_print("DYNAMIC_PROPERTY element=video_balance property=brightness value=%.2f\n", current);
    return G_SOURCE_CONTINUE;
}

static gboolean on_bus_message(GstBus *bus, GstMessage *message, gpointer user_data)
{
    AppState *app = user_data;
    (void) bus;

    switch (GST_MESSAGE_TYPE(message)) {
    case GST_MESSAGE_ERROR: {
        GError *error = NULL;
        gchar *debug_info = NULL;
        gst_message_parse_error(message, &error, &debug_info);
        g_printerr("PIPELINE_ERROR element=%s message=%s\n",
                   GST_OBJECT_NAME(message->src), error->message);
        g_printerr("Debug information: %s\n", debug_info ? debug_info : "(none)");
        g_clear_error(&error);
        g_free(debug_info);
        app->error_happened = TRUE;
        g_main_loop_quit(app->loop);
        break;
    }
    case GST_MESSAGE_WARNING: {
        GError *warning = NULL;
        gchar *debug_info = NULL;
        gst_message_parse_warning(message, &warning, &debug_info);
        g_printerr("PIPELINE_WARNING element=%s message=%s\n",
                   GST_OBJECT_NAME(message->src), warning->message);
        g_printerr("Debug information: %s\n", debug_info ? debug_info : "(none)");
        g_clear_error(&warning);
        g_free(debug_info);
        break;
    }
    case GST_MESSAGE_EOS:
        g_print("EOS_RECEIVED all sinks finished, recording finalized\n");
        app->eos_received = TRUE;
        g_main_loop_quit(app->loop);
        break;
    case GST_MESSAGE_STATE_CHANGED:
        /* only the state of the whole pipeline, not of every element */
        if (GST_MESSAGE_SRC(message) == GST_OBJECT(app->pipeline)) {
            GstState old_state, new_state, pending;
            gst_message_parse_state_changed(message, &old_state, &new_state, &pending);
            g_print("PIPELINE_STATE %s -> %s\n",
                    gst_element_state_get_name(old_state), gst_element_state_get_name(new_state));
            if (new_state == GST_STATE_PLAYING) {
                /* written only if GST_DEBUG_DUMP_DOT_DIR is set */
                GST_DEBUG_BIN_TO_DOT_FILE(GST_BIN(app->pipeline), GST_DEBUG_GRAPH_SHOW_ALL,
                                          "monitor_sender_playing");
            }
        }
        break;
    default:
        break;
    }
    return G_SOURCE_CONTINUE;
}

static void remove_source(guint *id)
{
    if (*id != 0) {
        g_source_remove(*id);
        *id = 0;
    }
}

int main(int argc, char *argv[])
{
    Options options = { 0 };
    AppState app = { 0 };
    GError *error = NULL;
    int exit_code = EXIT_OK;

    /* no buffering: the log must be complete even if we are killed by a timeout */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    /* parse_options also handles the GStreamer options, gst_init after it */
    if (!parse_options(argc, argv, &options)) {
        free_options(&options);
        return EXIT_USAGE;
    }
    gst_init(NULL, NULL);

    gchar *description = build_pipeline_description(&options);
    g_print("CONFIG pattern=%s size=%dx%d fps=%d codec=%s destination=%s:%d output=%s duration=%d headless=%s\n",
            options.pattern, options.width, options.height, options.fps, options.codec,
            options.host, options.port, options.output, options.duration,
            options.headless ? "yes" : "no");

    app.pipeline = gst_parse_launch(description, &error);
    if (app.pipeline == NULL || error != NULL) {
        /* error can be set with a non-NULL pipeline (e.g. missing property), treat both as fatal */
        g_printerr("ERROR: cannot create the pipeline: %s\n", error ? error->message : "unknown error");
        g_printerr("Pipeline description was:\n%s\n", description);
        g_clear_error(&error);
        if (app.pipeline)
            gst_object_unref(app.pipeline);
        g_free(description);
        free_options(&options);
        gst_deinit();
        return EXIT_RUNTIME;
    }
    g_free(description);

    app.options = &options;
    app.video_balance = gst_bin_get_by_name(GST_BIN(app.pipeline), "video_balance");
    if (app.video_balance == NULL) {
        g_printerr("ERROR: element 'video_balance' not found in the pipeline\n");
        gst_object_unref(app.pipeline);
        free_options(&options);
        gst_deinit();
        return EXIT_RUNTIME;
    }

    app.loop = g_main_loop_new(NULL, FALSE);
    GstBus *bus = gst_element_get_bus(app.pipeline);
    guint bus_watch_id = gst_bus_add_watch(bus, on_bus_message, &app);
    gst_object_unref(bus);

    signal(SIGINT, on_sigint);
    app.interrupt_timer_id = g_timeout_add(100, check_interrupt, &app);
    app.dynamic_timer_id = g_timeout_add_seconds(DYNAMIC_PERIOD_SECONDS, change_dynamic_property, &app);
    if (options.duration > 0)
        app.duration_timer_id = g_timeout_add_seconds(options.duration, on_duration_elapsed, &app);

    if (gst_element_set_state(app.pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        g_printerr("ERROR: the pipeline could not go to PLAYING\n");
        app.error_happened = TRUE;
        /* the bus usually has the real error, show it */
        GstMessage *message = gst_bus_pop_filtered(GST_ELEMENT_BUS(app.pipeline), GST_MESSAGE_ERROR);
        if (message) {
            on_bus_message(NULL, message, &app);
            gst_message_unref(message);
        }
    } else {
        g_print("RUNNING %s\n", options.duration > 0 ? "until the duration expires" : "until Ctrl+C");
        g_main_loop_run(app.loop);
    }

    /* ---- cleanup */
    remove_source(&app.duration_timer_id);
    remove_source(&app.dynamic_timer_id);
    remove_source(&app.eos_timeout_id);
    remove_source(&app.interrupt_timer_id);
    g_source_remove(bus_watch_id);

    gst_element_set_state(app.pipeline, GST_STATE_NULL);
    g_print("PIPELINE_STATE -> NULL\n");

    if (app.error_happened || !app.eos_received)
        exit_code = EXIT_RUNTIME;

    gst_object_unref(app.video_balance);
    gst_object_unref(app.pipeline);
    g_main_loop_unref(app.loop);
    free_options(&options);
    gst_deinit();

    g_print("EXIT code=%d\n", exit_code);
    return exit_code;
}
