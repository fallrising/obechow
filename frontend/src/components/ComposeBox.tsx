import { useState } from 'react'

import { createPost } from '@/api/posts'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'

const MAX_LENGTH = 280

interface ComposeBoxProps {
  author: string
  onAuthorChange: (author: string) => void
  onPosted: () => void
}

export function ComposeBox({ author, onAuthorChange, onPosted }: ComposeBoxProps) {
  const [content, setContent] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const remaining = MAX_LENGTH - content.length
  const canPost =
    author.trim().length > 0 &&
    content.trim().length > 0 &&
    content.length <= MAX_LENGTH &&
    !submitting

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault()
    if (!canPost) return

    setSubmitting(true)
    setError(null)
    try {
      await createPost(author.trim(), content.trim())
      setContent('')
      onPosted()
    } catch {
      setError('Failed to post. Please try again.')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <Card className="shrink-0">
      <CardHeader>
        <CardTitle>Compose</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-3">
          <Input
            placeholder="Your name"
            value={author}
            onChange={(e) => onAuthorChange(e.target.value)}
          />
          <Textarea
            placeholder="What's happening?"
            value={content}
            onChange={(e) => setContent(e.target.value.slice(0, MAX_LENGTH))}
            rows={3}
          />
          <div className="flex items-center justify-between">
            <span
              className={
                remaining < 20
                  ? 'text-sm text-[var(--color-destructive)]'
                  : 'text-sm text-[var(--color-muted-foreground)]'
              }
            >
              {remaining}
            </span>
            <Button type="submit" disabled={!canPost}>
              {submitting ? 'Posting…' : 'Post'}
            </Button>
          </div>
          {error && (
            <p className="text-sm text-[var(--color-destructive)]">{error}</p>
          )}
        </form>
      </CardContent>
    </Card>
  )
}