package test_unit_http_cs

// import http "../../../vendor/odin-http"
import "core:testing"

@(test)
test_http_cs_nop :: proc(t: ^testing.T) {
	testing.expect(t, false == false, "")
}
