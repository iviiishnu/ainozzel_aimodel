package com.example.spring_backend.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withException;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import java.io.IOException;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestTemplate;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

class CropServiceTest {

    private static final String ML = "http://ml.test:5010";
    private final ObjectMapper json = new ObjectMapper();
    private MockRestServiceServer server;
    private CropService service;

    @BeforeEach
    void setUp() {
        RestTemplate rest = new RestTemplate();
        server = MockRestServiceServer.createServer(rest);
        service = new CropService(rest, ML + "//");   // trailing slashes are trimmed
    }

    private static MockMultipartFile image() {
        return new MockMultipartFile("file", "leaf.jpg", "image/jpeg", new byte[] {1, 2, 3});
    }

    @Test
    void successIsRelayedAsJson() throws Exception {
        server.expect(requestTo(ML + "/api/crop/analyze")).andExpect(method(HttpMethod.POST))
                .andRespond(withSuccess("{\"disease\":\"Rust\"}", MediaType.APPLICATION_JSON));
        ResponseEntity<String> r = service.analyze(image());
        assertEquals(200, r.getStatusCode().value());
        assertEquals(MediaType.APPLICATION_JSON, r.getHeaders().getContentType());
        assertEquals("Rust", json.readTree(r.getBody()).get("disease").asText());
    }

    @Test
    void mlClientErrorPassesThroughUnchanged() throws Exception {
        String body = "{\"error\":\"No leaf detected.\"}";
        server.expect(requestTo(ML + "/api/crop/analyze"))
                .andRespond(withStatus(HttpStatus.BAD_REQUEST).contentType(MediaType.APPLICATION_JSON).body(body));
        ResponseEntity<String> r = service.analyze(image());
        assertEquals(400, r.getStatusCode().value());
        assertEquals(body, r.getBody());
    }

    @Test
    void mlServerErrorKeepsItsStatus() throws Exception {
        server.expect(requestTo(ML + "/api/crop/analyze"))
                .andRespond(withStatus(HttpStatus.INTERNAL_SERVER_ERROR).body("{\"error\":\"Prediction failed.\"}"));
        assertEquals(500, service.analyze(image()).getStatusCode().value());
    }

    @Test
    void unreachableMlServiceIs503WithValidJsonEvenForAwkwardMessages() throws Exception {
        server.expect(requestTo(ML + "/health"))
                .andRespond(withException(new IOException("refused \"quoted\"\nsecond line\ttab \\ slash")));
        ResponseEntity<String> r = service.health();
        assertEquals(503, r.getStatusCode().value());
        JsonNode node = json.readTree(r.getBody());       // must parse
        assertEquals("ML service unavailable", node.get("error").asText());
        assertTrue(node.get("details").asText().contains("second line"));
    }
}
