#include <emscripten.h>
int hxn_file_agent(unsigned address) {
  return MAIN_THREAD_EM_ASM_INT({
    if (typeof document === 'undefined') return 0;
    import(new URL('./hxn_file.mjs', location.href)).then(agent => {
      agent.start({memory: wasmMemory, address: $0, fail: error => abort('file agent: ' + error)});
    }).catch(error => abort('file agent: ' + error));
    return 1;
  }, address);
}
