package com.example.spring_backend.controller;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import com.example.spring_backend.config.CorsConfig;
import com.example.spring_backend.service.CropService;

@WebMvcTest(CropController.class)
@org.springframework.context.annotation.Import(CorsConfig.class)
class CropControllerTest {

    @Autowired
    MockMvc mvc;

    @MockitoBean
    CropService cropService;

    @Test
    void testEndpointResponds() throws Exception {
        mvc.perform(get("/api/crop/test"))
                .andExpect(status().isOk())
                .andExpect(content().string("Crop API is working!"));
    }

    @Test
    void postWithoutMultipartIsABadRequestNotAServerError() throws Exception {
        mvc.perform(post("/api/crop/analyze"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").exists())
                .andExpect(jsonPath("$.trace").doesNotExist());
    }

    @Test
    void multipartWithWrongFieldNameIsABadRequest() throws Exception {
        MockMultipartFile wrong = new MockMultipartFile("image", "leaf.jpg", "image/jpeg", new byte[] {1});
        mvc.perform(multipart("/api/crop/analyze").file(wrong))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").exists())
                .andExpect(jsonPath("$.trace").doesNotExist());
    }

    @Test
    void validUploadIsForwardedAndMlStatusIsRelayed() throws Exception {
        when(cropService.analyze(any())).thenReturn(ResponseEntity.status(200)
                .contentType(MediaType.APPLICATION_JSON).body("{\"disease\":\"Rust\"}"));
        MockMultipartFile file = new MockMultipartFile("file", "leaf.jpg", "image/jpeg", new byte[] {1, 2, 3});
        mvc.perform(multipart("/api/crop/analyze").file(file))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.disease").value("Rust"));
    }

    @Test
    void getOnAnalyzeIsMethodNotAllowed() throws Exception {
        mvc.perform(get("/api/crop/analyze")).andExpect(status().isMethodNotAllowed());
    }
}
