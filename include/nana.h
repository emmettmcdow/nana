// nana.h
#include <stdbool.h>
#import <Foundation/Foundation.h> 

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
