package com.example.spring_backend.config;

import java.time.Duration;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.client.RestTemplateBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.RestTemplate;

/** HTTP client used to call the Python ML service (timeouts from application.properties). */
@Configuration
public class RestClientConfig {

    @Bean
    RestTemplate restTemplate(
            RestTemplateBuilder builder,
            @Value("${ai.service.connect-timeout}") Duration connectTimeout,
            @Value("${ai.service.read-timeout}") Duration readTimeout) {
        return builder
                .connectTimeout(connectTimeout)
                .readTimeout(readTimeout)
                .build();
    }
}
