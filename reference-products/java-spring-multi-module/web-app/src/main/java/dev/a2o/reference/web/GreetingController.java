package dev.a2o.reference.web;

import dev.a2o.reference.utility.GreetingFormatter;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
class GreetingController {
    @GetMapping("/greetings/{name}")
    Map<String, String> greeting(@PathVariable String name) {
        return Map.of("message", GreetingFormatter.formatGreeting(name));
    }

    @GetMapping("/health")
    Map<String, String> health() {
        return Map.of("status", "ok");
    }
}
