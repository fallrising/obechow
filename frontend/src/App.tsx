import { useState } from 'react'

import { ComposeBox } from '@/components/ComposeBox'
import { PostColumn } from '@/components/PostColumn'

function App() {
  const [author, setAuthor] = useState(
    () => localStorage.getItem('skan-author') ?? '',
  )
  const [mineFilter, setMineFilter] = useState(author)
  const [searchQuery, setSearchQuery] = useState('')
  const [refreshKey, setRefreshKey] = useState(0)

  function handleAuthorChange(value: string) {
    setAuthor(value)
    localStorage.setItem('skan-author', value)
    setMineFilter(value)
  }

  function handlePosted() {
    setRefreshKey((k) => k + 1)
  }

  return (
    <div className="flex min-h-screen flex-col bg-[var(--color-background)]">
      <header className="border-b border-[var(--color-border)] px-6 py-4">
        <h1 className="text-2xl font-bold tracking-tight">Skan</h1>
        <p className="text-sm text-[var(--color-muted-foreground)]">
          A minimal Twitter deck
        </p>
      </header>

      <div className="flex flex-1 flex-col gap-4 p-4 lg:flex-row">
        <div className="w-full lg:w-80">
          <ComposeBox
            author={author}
            onAuthorChange={handleAuthorChange}
            onPosted={handlePosted}
          />
        </div>

        <div className="flex flex-1 gap-4 overflow-x-auto pb-4">
          <PostColumn title="All" refreshKey={refreshKey} />
          <PostColumn
            title="Mine"
            author={mineFilter || undefined}
            showAuthorInput
            authorValue={mineFilter}
            onAuthorValueChange={setMineFilter}
            refreshKey={refreshKey}
          />
          <PostColumn
            title="Search"
            q={searchQuery || undefined}
            showSearchInput
            searchValue={searchQuery}
            onSearchValueChange={setSearchQuery}
            refreshKey={refreshKey}
          />
        </div>
      </div>
    </div>
  )
}

export default App