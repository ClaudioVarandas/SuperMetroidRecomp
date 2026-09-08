#pragma once

#include <stdbool.h>
#include <stdint.h>

enum { SM_HEIGHT = 224, SM_STOCK_WIDTH = 256, SM_MAX_WIDTH = 684 };
#define SM_SIMULATION_HZ 60.098811862

typedef enum SmAspect {
  SM_ASPECT_STOCK,
  SM_ASPECT_16_9,
  SM_ASPECT_21_9,
  SM_ASPECT_32_9,
  SM_ASPECT_FIT,
  SM_ASPECT_COUNT
} SmAspect;

typedef struct SmVideoSettings {
  bool enhanced;
  SmAspect aspect;
  unsigned fps; /* 0 = display refresh (Auto). */
  bool fps_enabled;
  bool hud_anchored; /* Anchor energy left and minimap right. */
} SmVideoSettings;

extern SmVideoSettings g_sm_video;

typedef struct SmViewport {
  int width, extra;
  double aspect;
  bool enhanced;
} SmViewport;

typedef struct SmRect { int x, y, w, h; } SmRect;

void SmVideoDefaults(SmVideoSettings *settings);
const char *SmAspectName(SmAspect aspect);
bool SmParseAspect(const char *text, SmAspect *aspect);
bool SmValidFps(unsigned fps);
double SmPresentationHz(unsigned fps, double refresh);
SmViewport SmCalculateViewport(const SmVideoSettings *settings,
                                     int drawable_width, int drawable_height);
SmRect SmDestination(SmViewport viewport, int width, int height);
int SmHudAnchorX(SmViewport viewport, int x, int anchor);
bool SmVideoLoad(SmVideoSettings *settings, const char *path);
bool SmVideoSave(const SmVideoSettings *settings, const char *path);

/* Monotonic time in seconds. Simulation debt is never discarded here.
 * Hosts explicitly reset on pause/minimize/load, and bound catch-up batches
 * to keep pumping events when a machine cannot sustain the original rate. */
typedef struct SmClock {
  double next_simulation, next_presentation, presentation_hz;
  uint64_t simulation_frames, presentations, missed_presentations;
} SmClock;
void SmClockReset(SmClock *clock, double now, double presentation_hz);
bool SmClockSimulationDue(const SmClock *clock, double now);
void SmClockSimulationDone(SmClock *clock);
bool SmClockPresentationDue(const SmClock *clock, double now);
void SmClockPresentationDone(SmClock *clock, double now);
double SmClockAlpha(const SmClock *clock, double now);
double SmClockNextDeadline(const SmClock *clock);
