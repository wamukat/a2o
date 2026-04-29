package dev.a2o.reference.utility;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class GreetingFormatterTest {
    @Test
    void formatsGreetingWithTrimmedName() {
        assertThat(GreetingFormatter.formatGreeting("  Kanban  ")).isEqualTo("Hello, Kanban!");
    }

    @Test
    void usesDefaultNameWhenInputIsBlank() {
        assertThat(GreetingFormatter.formatGreeting("   ")).isEqualTo("Hello, A2O!");
    }
}
