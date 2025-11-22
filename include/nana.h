// nana.h

enum NanaError { 
  Success = 0,
  GenericFail = -8,
  DoubleInit = -9,
  NotInit = -10,
  PathTooLong = -11,
  FileNotFound = -12,
  InvalidFiletype = -13,
};

int nana_init(const char *, unsigned int);
int nana_deinit(void);
int nana_create(void);
int nana_import(const char *, unsigned int);
long nana_create_time(int);
long nana_mod_time(int);
int nana_search(const char *, int *, unsigned int, int);
int nana_write_all(int, const char *);
long nana_write_all_with_time(int, const char *);
int nana_read_all(int, char *, unsigned int);
const char * nana_doctor(const char *);

const char * nana_parse_markdown(const char *);
