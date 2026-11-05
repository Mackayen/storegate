import { useEffect, useRef, useState } from 'react'

// USB barcode scanner input. The scanner acts as a keyboard: it types the code and presses Enter.
// With keepFocus the field takes focus back after a scan so the next scan always lands here.
export default function ScanInput({
  onScan,
  placeholder = 'Scan or type a code, then press Enter',
  keepFocus = true,
  autoFocus = true,
}) {
  const ref = useRef(null)
  const [value, setValue] = useState('')

  useEffect(() => {
    if (autoFocus) ref.current?.focus()
  }, [autoFocus])

  // Not a <form>: this field sits inside the New movement form, and nested forms are invalid HTML.
  // In Chrome, pressing Enter in a nested form reloaded the page. Enter is handled here instead.
  function submit() {
    const code = value.trim()
    if (!code) return
    setValue('')
    onScan(code)
    if (keepFocus) ref.current?.focus()
  }

  function onKeyDown(e) {
    if (e.key === 'Enter') {
      e.preventDefault()
      e.stopPropagation()
      submit()
    }
  }

  return (
    <>
      <div className="scan">
        <input
          ref={ref}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={onKeyDown}
          enterKeyHint="go"
          placeholder={placeholder}
          autoComplete="off"
          autoCapitalize="off"
          spellCheck={false}
          maxLength={128}
          aria-label="Scan input"
        />
        <button type="button" onClick={submit}>Go</button>
      </div>
    </>
  )
}
