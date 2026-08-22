#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "text_util.h"

// UTF-8文字列をコードポイント列に変換
idris2rc2_TextBuffer* idris2rc2_utf8_to_codepoints(const char* utf8_str) {
    size_t len = strlen(utf8_str); // 仮の長さ
    
    // 構造体とバッファを1つのメモリブロックで確保
    idris2rc2_TextBuffer* buffer = malloc(sizeof(idris2rc2_TextBuffer) + sizeof(uint32_t) * len);
    if (!buffer) return NULL;

    buffer->len = len;
    for(size_t i = 0; i < len; ++i) {
        buffer->buf[i] = (uint32_t)utf8_str[i]; // 仮の変換
    }
    return buffer;
}

void idris2rc2_free_text_buffer(idris2rc2_TextBuffer* buf) {
    // 1回のmallocなので1回のfreeでよい
    free(buf);
}
