// Serial numbers printed under an item on a document or screen.
export default function SerialList({ serials }) {
  if (!serials?.length) return null
  return <div className="serials">Serial numbers: {serials.join(', ')}</div>
}
