package com.demo.userservice;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.method.configuration.EnableGlobalMethodSecurity;
import org.springframework.cloud.openfeign.EnableFeignClients;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.DeleteMapping;

import javax.validation.Valid;
import javax.validation.constraints.NotNull;
import javax.validation.constraints.Email;
import javax.validation.constraints.Size;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;
import java.util.Map;
import java.util.HashMap;

import io.micrometer.core.annotation.Timed;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Counter;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Zero Trust User Service
 * Demonstrates secure microservice architecture with:
 * - JWT-based authentication
 * - Role-based authorization
 * - Audit logging
 * - Security metrics
 * - Input validation
 * - Error handling
 */
@SpringBootApplication
@EnableWebSecurity
@EnableGlobalMethodSecurity(prePostEnabled = true)
@EnableFeignClients
public class UserServiceApplication {

    private static final Logger logger = LoggerFactory.getLogger(UserServiceApplication.class);

    public static void main(String[] args) {
        logger.info("Starting User Service with Zero Trust Security");
        SpringApplication.run(UserServiceApplication.class, args);
    }
}

@RestController
@RequestMapping("/api/v1/users")
class UserController {

    private static final Logger logger = LoggerFactory.getLogger(UserController.class);
    private static final Logger auditLogger = LoggerFactory.getLogger("AUDIT");

    private final Counter userAccessCounter;
    private final Counter userCreateCounter;
    private final Counter userUpdateCounter;
    private final Counter userDeleteCounter;
    private final Counter securityViolationCounter;

    @Value("${app.security.enable-audit:true}")
    private boolean auditEnabled;

    @Value("${app.version}")
    private String appVersion;

    public UserController(MeterRegistry meterRegistry) {
        this.userAccessCounter = Counter.builder("user.access.total")
            .description("Total user access attempts")
            .register(meterRegistry);

        this.userCreateCounter = Counter.builder("user.create.total")
            .description("Total user creation attempts")
            .register(meterRegistry);

        this.userUpdateCounter = Counter.builder("user.update.total")
            .description("Total user update attempts")
            .register(meterRegistry);

        this.userDeleteCounter = Counter.builder("user.delete.total")
            .description("Total user deletion attempts")
            .register(meterRegistry);

        this.securityViolationCounter = Counter.builder("security.violation.total")
            .description("Total security violations")
            .register(meterRegistry);
    }

    /**
     * Get all users - Admin only
     */
    @GetMapping
    @PreAuthorize("hasRole('ADMIN')")
    @Timed(value = "user.list.time", description = "Time taken to list users")
    public ResponseEntity<List<User>> getAllUsers() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        userAccessCounter.increment();

        auditLog("LIST_USERS", auth.getName(), "SUCCESS", null);

        // Mock data - in real implementation, this would come from database
        List<User> users = List.of(
            new User("1", "john.doe@example.com", "John", "Doe", List.of("USER"), true),
            new User("2", "jane.admin@example.com", "Jane", "Admin", List.of("ADMIN", "USER"), true),
            new User("3", "security.officer@example.com", "Security", "Officer", List.of("SECURITY_OFFICER"), true)
        );

        return ResponseEntity.ok(users);
    }

    /**
     * Get user by ID - User can access own data, Admin can access any
     */
    @GetMapping("/{userId}")
    @PreAuthorize("hasRole('ADMIN') or #userId == authentication.name")
    @Timed(value = "user.get.time", description = "Time taken to get user")
    public ResponseEntity<User> getUserById(@PathVariable String userId) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        userAccessCounter.increment();

        // Security check - users can only access their own data unless admin
        if (!auth.getAuthorities().stream()
                .anyMatch(a -> a.getAuthority().equals("ROLE_ADMIN")) &&
            !userId.equals(auth.getName())) {

            securityViolationCounter.increment();
            auditLog("GET_USER", auth.getName(), "SECURITY_VIOLATION",
                Map.of("attempted_user_id", userId, "reason", "unauthorized_access"));

            return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
        }

        auditLog("GET_USER", auth.getName(), "SUCCESS", Map.of("user_id", userId));

        // Mock user data
        User user = new User(userId, userId + "@example.com", "User", "Name",
            List.of("USER"), true);

        return ResponseEntity.ok(user);
    }

    /**
     * Create new user - Admin only
     */
    @PostMapping
    @PreAuthorize("hasRole('ADMIN')")
    @Timed(value = "user.create.time", description = "Time taken to create user")
    public ResponseEntity<User> createUser(@Valid @RequestBody CreateUserRequest request) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        userCreateCounter.increment();

        // Input validation and sanitization
        if (request.getEmail() == null || !isValidEmail(request.getEmail())) {
            auditLog("CREATE_USER", auth.getName(), "VALIDATION_ERROR",
                Map.of("reason", "invalid_email"));
            return ResponseEntity.badRequest().build();
        }

        // Create user (mock implementation)
        String userId = UUID.randomUUID().toString();
        User newUser = new User(userId, request.getEmail(), request.getFirstName(),
            request.getLastName(), List.of("USER"), true);

        auditLog("CREATE_USER", auth.getName(), "SUCCESS",
            Map.of("created_user_id", userId, "email", request.getEmail()));

        return ResponseEntity.status(HttpStatus.CREATED).body(newUser);
    }

    /**
     * Update user - User can update own data, Admin can update any
     */
    @PutMapping("/{userId}")
    @PreAuthorize("hasRole('ADMIN') or #userId == authentication.name")
    @Timed(value = "user.update.time", description = "Time taken to update user")
    public ResponseEntity<User> updateUser(@PathVariable String userId,
                                          @Valid @RequestBody UpdateUserRequest request) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        userUpdateCounter.increment();

        // Security validation
        if (!hasUpdatePermission(auth, userId)) {
            securityViolationCounter.increment();
            auditLog("UPDATE_USER", auth.getName(), "SECURITY_VIOLATION",
                Map.of("attempted_user_id", userId));
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
        }

        // Update user (mock implementation)
        User updatedUser = new User(userId, request.getEmail(), request.getFirstName(),
            request.getLastName(), List.of("USER"), true);

        auditLog("UPDATE_USER", auth.getName(), "SUCCESS",
            Map.of("updated_user_id", userId));

        return ResponseEntity.ok(updatedUser);
    }

    /**
     * Delete user - Admin only
     */
    @DeleteMapping("/{userId}")
    @PreAuthorize("hasRole('ADMIN')")
    @Timed(value = "user.delete.time", description = "Time taken to delete user")
    public ResponseEntity<Void> deleteUser(@PathVariable String userId) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        userDeleteCounter.increment();

        // Prevent self-deletion
        if (userId.equals(auth.getName())) {
            auditLog("DELETE_USER", auth.getName(), "VALIDATION_ERROR",
                Map.of("reason", "self_deletion_attempt"));
            return ResponseEntity.badRequest().build();
        }

        auditLog("DELETE_USER", auth.getName(), "SUCCESS",
            Map.of("deleted_user_id", userId));

        return ResponseEntity.noContent().build();
    }

    /**
     * Health check endpoint
     */
    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, Object> health = new HashMap<>();
        health.put("status", "UP");
        health.put("timestamp", LocalDateTime.now());
        health.put("version", appVersion);
        health.put("service", "user-service");
        health.put("security", Map.of(
            "authentication", "JWT",
            "authorization", "RBAC",
            "audit", auditEnabled
        ));

        return ResponseEntity.ok(health);
    }

    // Private helper methods

    private void auditLog(String action, String principal, String result, Map<String, Object> details) {
        if (!auditEnabled) return;

        Map<String, Object> auditEvent = new HashMap<>();
        auditEvent.put("timestamp", LocalDateTime.now());
        auditEvent.put("action", action);
        auditEvent.put("principal", principal);
        auditEvent.put("result", result);
        auditEvent.put("service", "user-service");
        auditEvent.put("details", details);

        auditLogger.info("AUDIT: {}", auditEvent);
    }

    private boolean isValidEmail(String email) {
        return email != null && email.matches("^[A-Za-z0-9+_.-]+@(.+)$");
    }

    private boolean hasUpdatePermission(Authentication auth, String userId) {
        return auth.getAuthorities().stream()
                .anyMatch(a -> a.getAuthority().equals("ROLE_ADMIN")) ||
               userId.equals(auth.getName());
    }
}

// Data Transfer Objects

class User {
    private String id;
    private String email;
    private String firstName;
    private String lastName;
    private List<String> roles;
    private boolean active;
    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;

    public User() {}

    public User(String id, String email, String firstName, String lastName,
                List<String> roles, boolean active) {
        this.id = id;
        this.email = email;
        this.firstName = firstName;
        this.lastName = lastName;
        this.roles = roles;
        this.active = active;
        this.createdAt = LocalDateTime.now();
        this.updatedAt = LocalDateTime.now();
    }

    // Getters and setters
    public String getId() { return id; }
    public void setId(String id) { this.id = id; }

    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }

    public String getFirstName() { return firstName; }
    public void setFirstName(String firstName) { this.firstName = firstName; }

    public String getLastName() { return lastName; }
    public void setLastName(String lastName) { this.lastName = lastName; }

    public List<String> getRoles() { return roles; }
    public void setRoles(List<String> roles) { this.roles = roles; }

    public boolean isActive() { return active; }
    public void setActive(boolean active) { this.active = active; }

    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }

    public LocalDateTime getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(LocalDateTime updatedAt) { this.updatedAt = updatedAt; }
}

class CreateUserRequest {
    @NotNull
    @Email
    private String email;

    @NotNull
    @Size(min = 1, max = 50)
    private String firstName;

    @NotNull
    @Size(min = 1, max = 50)
    private String lastName;

    // Getters and setters
    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }

    public String getFirstName() { return firstName; }
    public void setFirstName(String firstName) { this.firstName = firstName; }

    public String getLastName() { return lastName; }
    public void setLastName(String lastName) { this.lastName = lastName; }
}

class UpdateUserRequest {
    @Email
    private String email;

    @Size(min = 1, max = 50)
    private String firstName;

    @Size(min = 1, max = 50)
    private String lastName;

    // Getters and setters
    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }

    public String getFirstName() { return firstName; }
    public void setFirstName(String firstName) { this.firstName = firstName; }

    public String getLastName() { return lastName; }
    public void setLastName(String lastName) { this.lastName = lastName; }
}