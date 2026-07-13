package com.skan.controller;

import com.skan.dto.CreatePostRequest;
import com.skan.entity.Post;
import com.skan.repository.PostRepository;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequestMapping("/api/posts")
public class PostController {

    private final PostRepository postRepository;

    public PostController(PostRepository postRepository) {
        this.postRepository = postRepository;
    }

    @GetMapping
    public List<Post> getPosts(
            @RequestParam(required = false) String author,
            @RequestParam(required = false) String q) {
        return postRepository.findFiltered(author, q, PageRequest.of(0, 50));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Post createPost(@RequestBody CreatePostRequest request) {
        if (request.getAuthor() == null || request.getAuthor().isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "author is required");
        }
        if (request.getContent() == null || request.getContent().isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "content is required");
        }
        if (request.getContent().length() > 280) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "content must be at most 280 characters");
        }

        Post post = new Post(request.getAuthor().trim(), request.getContent().trim());
        return postRepository.save(post);
    }
}