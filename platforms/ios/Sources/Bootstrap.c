#include <dispatch/dispatch.h>
extern void ClipMeshStart(void);
__attribute__((constructor)) static void clipmesh_load(void) { ClipMeshStart(); }
