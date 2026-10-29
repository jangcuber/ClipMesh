#include <stdio.h>
#include <unistd.h>
// A controlled live-but-offline helper: it must never trap the UI in reconnecting forever.
int main(void) {
    for (;;) {
        puts("{\"type\":\"status\",\"state\":\"disconnected\",\"connected\":false,\"transport\":\"reconnecting\",\"peers\":0}");
        fflush(stdout); usleep(50000);
    }
}
