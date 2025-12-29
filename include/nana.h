// nana.h
#include <stdbool.h>

enum NanaError { 
  Success = 0,
  GenericFail = -8,
  DoubleInit = -9,
  NotInit = -10,
  PathTooLong = -11,
  FileNotFound = -12,
  InvalidFiletype = -13,
};

typedef struct {
    unsigned int id;
    unsigned int start_i;
    unsigned int end_i;
    unsigned int highlight_start_i;
    unsigned int highlight_end_i;
} CSearchResult;

#define TITLE_BUF_SZ 64

int nana_init(const char *);
int nana_deinit(void);
int nana_create(void);
int nana_import(const char *, char *, unsigned int);
long nana_create_time(int);
long nana_mod_time(int);
int nana_search(const char *, CSearchResult *, unsigned int);
int nana_index(int *, unsigned int, int);
int nana_write_all(int, const char *);
long nana_write_all_with_time(int, const char *);
int nana_read_all(int, char *, unsigned int);
const char * nana_title(int, char *);
const char * nana_doctor(const char *);
void nana_doctor_finish(void);
void nana_doctor_finish2(void);

const char * nana_parse_markdown(const char *);
