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
    unsigned int clicks;     // AppKit clickCount of the held press; 2 is a double-click
    unsigned int modifiers;  // NANA_MOD_* bitmask
    bool system_dark;        // host window is in a dark appearance
    double scroll_dy;        // wheel/trackpad points this frame; + scrolls toward doc start
    const char *text_utf8;   // UTF-8 text entered this frame; borrowed for the call only.
                             // A pointer rather than a fixed array because a paste is
                             // unbounded. May be NULL when text_len is 0.
    unsigned int text_len;   // byte length of text_utf8
    unsigned int backspaces; // count of Backspace presses this frame
    unsigned int escapes;    // count of Escape presses this frame
    unsigned int ups;        // count of up presses this frame
    unsigned int downs;      // count of down presses this frame
    unsigned int lefts;      // count of left presses this frame
    unsigned int rights;     // count of right presses this frame
} NanaInput;

// `path` may be NULL, meaning "use the default workspace". Pass a directory when the host has
// already gained access to one (a resolved security-scoped bookmark, say).
void nana_render_init(const char *path);
// Switch workspaces. The host must already hold access to the directory. Returns false if the
// switch failed, in which case no workspace is open.
bool nana_render_set_workspace(const char *path);
void nana_render_frame(CGContextRef ctx, double width, double height, const NanaInput *input);
void nana_render_deinit(void);

// Selection access, for the host's copy/cut/paste plumbing. Paste needs nothing here: pasted
// text goes in through NanaInput.text_utf8 like any other input.
unsigned int nana_render_selection_len(void);              // bytes, 0 if nothing selected
int nana_render_copy_selection(char *out, unsigned int);   // bytes written, or 0
int nana_render_cut_selection(char *out, unsigned int);    // copies, then deletes
void nana_render_select_all(void);

// Aim the editor at a canvas point (top-left origin, points), as a right-click does: a point
// inside the selection leaves it alone, anywhere else takes the word under the pointer or the
// bare caret. Applied by the next frame, so force a redraw before reading the selection back.
void nana_render_context_click(double x, double y);

// Undo/redo. Return false when the corresponding stack is empty, so the host can fall back to
// AppKit's usual "nothing to undo" behaviour rather than silently swallowing the shortcut.
// Settings. Owned and persisted by Zig; the host reads them back for its own UI.
double nana_render_font_size(void);
void nana_render_set_font_size(double size);
void nana_render_adjust_font_size(double delta);

bool nana_render_undo(void);
bool nana_render_redo(void);
