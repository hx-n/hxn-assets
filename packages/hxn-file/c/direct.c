#include <emscripten.h>
EM_JS(int, hxn_file_start_direct, (unsigned address), {
  if (typeof document === 'undefined') return 0;
  /*AGENT*/
  Module.hxnFileExecute = service({get buffer() {return HEAPU8.buffer;}}, address).execute;
  return 1;
});
EM_JS(void, hxn_file_execute, (), { Module.hxnFileExecute(); });
int hxn_file_agent(unsigned address) { return hxn_file_start_direct(address); }
