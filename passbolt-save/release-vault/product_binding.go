package main

import "C"

import (
	"encoding/json"
	"unsafe"
)

//export ProductVaultRead
func ProductVaultRead(input *C.char, size C.int, output *C.char, capacity C.int) (written C.int) {
	if input == nil || size <= 0 || size > productLimit || output == nil || capacity != productLimit {
		return -1
	}
	in := unsafe.Slice((*byte)(unsafe.Pointer(input)), int(size))
	out := unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity))
	defer func() {
		if recover() != nil {
			clear(out)
			written = -1
		}
	}()
	var request struct {
		productVault
		productCall
	}
	if err := json.Unmarshal(in, &request); err != nil {
		return -1
	}
	result, err := request.productVault.call(request.productCall)
	if err != nil {
		return -1
	}
	payload, err := json.Marshal(result)
	if err != nil || len(payload) > len(out) {
		return -1
	}
	defer clear(payload)
	return C.int(copy(out, payload))
}
