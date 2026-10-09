/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "driftwm_desktop.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void request(DriftDesktop *scene, const char *json, const char *expected) {
    char *response = driftwm_desktop_request(scene, (const uint8_t *)json, strlen(json));
    assert(response != NULL);
    if (strstr(response, expected) == NULL) {
        fprintf(stderr, "Unexpected response: %s\n", response);
        assert(0);
    }
    driftwm_desktop_response_free(response);
}
int main(void) {
    DriftDesktop *scene = driftwm_desktop_create();
    assert(scene != NULL);
    request(scene, "{\"version\":1,\"command\":{\"op\":\"register_output\",\"stable_id\":\"c-display\",\"screen_bounds\":{\"origin\":{\"x\":0,\"y\":0},\"size\":{\"width\":100,\"height\":100}}}}", "\"output\":1");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"attach\",\"identity\":{\"pid\":123,\"birth_sec\":1800000000,\"birth_usec\":1,\"wid\":456},\"bundle_id\":\"org.example.fixture\",\"title\":\"C ABI\",\"buffer\":{\"width\":200,\"height\":200},\"source_rect\":{\"origin\":{\"x\":0,\"y\":0},\"size\":{\"width\":100,\"height\":100}}}}", "\"window\":1");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"input\",\"output\":1,\"screen\":{\"x\":20,\"y\":30},\"identity\":{\"pid\":123,\"birth_sec\":1800000000,\"birth_usec\":1,\"wid\":456}}}", "\"native_screen\":{\"x\":20.0,\"y\":30.0}");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"snapshot\",\"unknown\":true}}", "\"ok\":false");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"focus\",\"window\":1}}", "\"op\":\"focus_native_window\"");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"snapshot\"}}", "\"observed_native\":null");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"focus_result\",\"window\":1,\"identity\":{\"pid\":123,\"birth_sec\":1800000000,\"birth_usec\":1,\"wid\":456},\"generation\":1,\"effect_id\":1,\"success\":true}}", "\"ok\":true");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"cycle_focus\",\"backward\":false,\"held\":true}}", "\"effect_id\":2");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"end_focus_cycle\"}}", "\"ok\":true");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"focus_result\",\"window\":1,\"identity\":{\"pid\":123,\"birth_sec\":1800000000,\"birth_usec\":1,\"wid\":456},\"generation\":1,\"effect_id\":2,\"success\":false}}", "\"ok\":true");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"snapshot\"}}", "\"history\":[1]");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"tick_navigation\",\"timestamp_ns\":0}}", "\"needs_frames\":false");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"navigate_window\",\"window\":1,\"output\":1,\"zoom_policy\":\"keep\"}}", "\"target_zoom\":1.0");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"tick_navigation\",\"timestamp_ns\":16666667}}", "\"needs_frames\":false");
    request(scene, "{\"version\":1,\"command\":{\"op\":\"cancel_navigation\",\"output\":1}}", "\"ok\":true");
    driftwm_desktop_destroy(scene);
    puts("C ABI controller smoke passed (logical controller only)");
    return 0;
}
