import { useEffect, useState } from 'react'

import { fetchPosts } from '@/api/posts'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import type { Post } from '@/types/post'

interface PostColumnProps {
  title: string
  author?: string
  q?: string
  showAuthorInput?: boolean
  authorValue?: string
  onAuthorValueChange?: (value: string) => void
  showSearchInput?: boolean
  searchValue?: string
  onSearchValueChange?: (value: string) => void
  refreshKey: number
}

function formatTime(iso: string) {
  return new Date(iso).toLocaleString()
}

export function PostColumn({
  title,
  author,
  q,
  showAuthorInput,
  authorValue,
  onAuthorValueChange,
  showSearchInput,
  searchValue,
  onSearchValueChange,
  refreshKey,
}: PostColumnProps) {
  const [posts, setPosts] = useState<Post[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    async function load() {
      try {
        const data = await fetchPosts({ author, q })
        if (!cancelled) {
          setPosts(data)
          setError(null)
        }
      } catch {
        if (!cancelled) {
          setError('Failed to load posts')
        }
      } finally {
        if (!cancelled) {
          setLoading(false)
        }
      }
    }

    setLoading(true)
    load()

    const interval = setInterval(load, 5000)
    return () => {
      cancelled = true
      clearInterval(interval)
    }
  }, [author, q, refreshKey])

  return (
    <div className="flex w-80 shrink-0 flex-col gap-3">
      <Card className="flex h-full flex-col">
        <CardHeader>
          <CardTitle>{title}</CardTitle>
          {showAuthorInput && (
            <Input
              placeholder="Filter by author"
              value={authorValue ?? ''}
              onChange={(e) => onAuthorValueChange?.(e.target.value)}
            />
          )}
          {showSearchInput && (
            <Input
              placeholder="Search posts"
              value={searchValue ?? ''}
              onChange={(e) => onSearchValueChange?.(e.target.value)}
            />
          )}
        </CardHeader>
        <CardContent className="flex-1 space-y-3 overflow-y-auto">
          {loading && posts.length === 0 && (
            <p className="text-sm text-[var(--color-muted-foreground)]">Loading…</p>
          )}
          {error && (
            <p className="text-sm text-[var(--color-destructive)]">{error}</p>
          )}
          {posts.map((post) => (
            <Card key={post.id} className="bg-[var(--color-muted)]">
              <CardContent className="space-y-1 p-3">
                <div className="flex items-baseline justify-between gap-2">
                  <span className="font-semibold">{post.author}</span>
                  <span className="text-xs text-[var(--color-muted-foreground)]">
                    {formatTime(post.createdAt)}
                  </span>
                </div>
                <p className="text-sm whitespace-pre-wrap">{post.content}</p>
              </CardContent>
            </Card>
          ))}
          {!loading && !error && posts.length === 0 && (
            <p className="text-sm text-[var(--color-muted-foreground)]">No posts yet</p>
          )}
        </CardContent>
      </Card>
    </div>
  )
}