// nana.h

enum Error { 
  Success = 0,
  DoubleInit = -1,
  NotInit = -2,
  DirCreationFail = -3,
  InitFail = -4,
  DeinitFail = -5,
  CreateFail = -6,
  GetFail = -7,
  WriteFail = -8,
  SearchFail = -9,
  ReadFail = -10,
  PathTooLong = -11,
  FileNotFound = -12,
};

int nana_init(const char *, unsigned int, const char *, unsigned int);
int nana_deinit();
int nana_create(void);
int nana_import(const char *, unsigned int);
int nana_create_time(int);
int nana_mod_time(int);

int nana_search(const char *, int *, unsigned int, int);
int nana_write_all(int, const char *);
int nana_read_all(int, char *, unsigned int);

// TODO
// int nana_search(char *);
// int nana_next_result(int);
// int nana_contents(int, char *, int);
// int nana_update(int, char *, int);
