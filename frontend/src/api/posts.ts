import type { Post } from '@/types/post'

export async function fetchPosts(params: {
  author?: string
  q?: string
}): Promise<Post[]> {
  const search = new URLSearchParams()
  if (params.author) search.set('author', params.author)
  if (params.q) search.set('q', params.q)

  const query = search.toString()
  const response = await fetch(`/api/posts${query ? `?${query}` : ''}`)
  if (!response.ok) {
    throw new Error('Failed to fetch posts')
  }
  return response.json()
}

export async function createPost(author: string, content: string): Promise<Post> {
  const response = await fetch('/api/posts', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ author, content }),
  })
  if (!response.ok) {
    throw new Error('Failed to create post')
  }
  return response.json()
}