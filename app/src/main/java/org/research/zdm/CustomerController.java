package org.research.zdm;

import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/customers")
public class CustomerController {

    public record CustomerRequest(String name, String email) {
    }

    private final CustomerRepository repo;

    public CustomerController(CustomerRepository repo) {
        this.repo = repo;
    }

    @PostMapping
    public ResponseEntity<Customer> create(@RequestBody CustomerRequest req) {
        return ResponseEntity.status(HttpStatus.CREATED).body(repo.create(req.name(), req.email()));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Customer> get(@PathVariable long id) {
        return ResponseEntity.of(repo.find(id));
    }

    @PutMapping("/{id}")
    public ResponseEntity<Void> rename(@PathVariable long id, @RequestBody CustomerRequest req) {
        return repo.rename(id, req.name()) ? ResponseEntity.noContent().build() : ResponseEntity.notFound().build();
    }

    /** Lets the probe and the pipeline confirm which application version is serving. */
    @GetMapping("/_mode")
    public Map<String, String> mode() {
        return Map.of("schemaMode", repo.mode().name());
    }
}
