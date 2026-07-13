package com.skan.repository;

import com.skan.entity.Post;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface PostRepository extends JpaRepository<Post, Long> {

    @Query("""
            SELECT p FROM Post p
            WHERE (:author IS NULL OR :author = '' OR p.author = :author)
              AND (:q IS NULL OR :q = '' OR LOWER(p.content) LIKE LOWER(CONCAT('%', :q, '%')))
            ORDER BY p.createdAt DESC
            """)
    List<Post> findFiltered(
            @Param("author") String author,
            @Param("q") String q,
            Pageable pageable);
}