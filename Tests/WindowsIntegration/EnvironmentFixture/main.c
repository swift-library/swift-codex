#if defined(_WIN32)
#include <windows.h>

/* This native process has no Swift runtime DLL dependency. Its PATH may be
   absent, without changing DLL lookup to make the test executable start. */
int main(void) {
  WCHAR value[256];
  char bytes[768];
  SetLastError(ERROR_SUCCESS);
  DWORD count = GetEnvironmentVariableW(L"PATH", value, 256);
  const char *output;
  DWORD length;
  if (count == 0 && GetLastError() == ERROR_ENVVAR_NOT_FOUND) {
    output = "<missing>\n";
    length = 10;
  } else if (count > 0 && count < 256) {
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value,
                                   (int)count, bytes, 767, NULL, NULL);
    if (size == 0) return 3;
    bytes[size] = '\n';
    output = bytes;
    length = (DWORD)size + 1;
  } else {
    return 4;
  }
  DWORD written = 0;
  if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output, length, &written, NULL))
    return 5;
  return written == length ? 0 : 6;
}
#else
int main(void) { return 1; }
#endif
