package dev.a2o.reference.utility;

public final class GreetingFormatter {
    private GreetingFormatter() {
    }

    public static String formatGreeting(String name) {
        String normalizedName = normalizeName(name);
        return "Hello, " + normalizedName + "!";
    }

    public static String normalizeName(String name) {
        if (name == null || name.isBlank()) {
            return "A2O";
        }
        return name.trim();
    }
}
