#include <stdint.h>
int32_t paperclip_mobile_probe(const uint8_t *seed, uint8_t *fingerprint);
char *paperclip_mobile_call(const char *request, const uint8_t *seed);
void paperclip_mobile_free(char *result);
