// Minimal check that the QQNT headers resolve via the <QQNT/...> prefix.
#include <QQNT/node_version.h>
#include <cstdio>

int main() {
  std::printf("QQNT SDK headers OK - bundled Node %s (NODE_MODULE_VERSION %d)\n",
              NODE_VERSION, NODE_MODULE_VERSION);
  return 0;
}
