// nana.h
#include <stdbool.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, NanaError) { 
  Success = 0,
  GenericFail = -8,
  DoubleInit = -9,
  NotInit = -10,
  PathTooLong = -11,
  FileNotFound = -12,
  InvalidFiletype = -13,
};

#define TITLE_BUF_SZ 64
#define N_SEARCH_HIGHLIGHTS 5

#define PATH_MAX 1024

typedef struct {
    char path[PATH_MAX];
    unsigned int start_i;
    unsigned int end_i;
    float similarity;
} CSearchResult;

typedef struct {
  char *content;
  unsigned int highlights[N_SEARCH_HIGHLIGHTS * 2];
} CSearchDetail;

int nana_init(const char *);
int nana_deinit(void);
int nana_create(char *, unsigned int);
int nana_import(const char *, char *, unsigned int);
long nana_create_time(const char *);
long nana_mod_time(const char *);
int nana_search(const char *, CSearchResult *, unsigned int);
int nana_search_detail(const char *, unsigned int, unsigned int, const char *, CSearchDetail *, bool);
int nana_index(char *, unsigned int, const char *);
int nana_write_all(const char *, const char *);
long nana_write_all_with_time(const char *, const char *);
int nana_read_all(const char *, char *, unsigned int);
const char * nana_title(const char *, char *);
int nana_doctor(void);

const char * nana_parse_markdown(const char *);

// ── Render scaffold ───────────────────────────────────────────────────────────
// A raylib-level immediate-mode surface. The Swift NanaCanvasView calls
// nana_render_frame once per display refresh with a CGContext to draw into and a
// snapshot of input for that frame.

typedef struct {
    float r, g, b, a;
} NanaColor;

typedef struct {
    double x, y, w, h;
} NanaRect;

// Modifier bit masks for NanaInput.modifiers.
#define NANA_MOD_SHIFT   (1u << 0)
#define NANA_MOD_CONTROL (1u << 1)
#define NANA_MOD_OPTION  (1u << 2)
#define NANA_MOD_COMMAND (1u << 3)

typedef struct {
    double mouse_x;          // top-left origin, points
    double mouse_y;
    bool mouse_down;
    unsigned int modifiers;  // NANA_MOD_* bitmask
    char text_utf8[64];      // UTF-8 text typed this frame (NUL-terminated)
    unsigned int text_len;   // byte length of text_utf8
    unsigned int backspaces; // count of Backspace presses this frame
    unsigned int ups;        // count of up presses this frame
    unsigned int downs;      // count of down presses this frame
    unsigned int lefts;      // count of left presses this frame
    unsigned int rights;     // count of right presses this frame
} NanaInput;

void nana_render_init(void);
void nana_render_frame(CGContextRef ctx, double width, double height, const NanaInput *input);
void nana_render_deinit(void);
