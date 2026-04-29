package dev.a2o.reference.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(GreetingController.class)
class GreetingControllerTest {
    @Autowired
    private MockMvc mockMvc;

    @Test
    void returnsGreetingFromUtilityLibrary() throws Exception {
        mockMvc.perform(get("/greetings/A2O"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.message").value("Hello, A2O!"));
    }

    @Test
    void returnsHealthStatus() throws Exception {
        mockMvc.perform(get("/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("ok"));
    }
}

