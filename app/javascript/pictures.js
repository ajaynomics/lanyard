// A picture made ready to send (attachments_controller): no side longer than
// 2,000 pixels, the most a model reads anyway, and no larger than the limit.
// A screenshot stays a PNG, so its text stays sharp, if that fits; anything
// else becomes a JPEG. HEIC and TIFF are converted where the browser can read
// them (Safari can); where it can't (Chrome can't read HEIC), it says so now
// rather than when the message is sent. Loaded only when a picture is added,
// so the thread's first load carries none of it.
//
// attachments_controller shows "Preparing…" on the thumbnail meanwhile, puts
// the ready picture in its place unless it was taken off, and holds a message
// sent before then (attachments#hold), which would otherwise go without it.
// Rails and the sidecar check the limits again; this saves a wasted upload.
export const MAX_SIDE = 2000
const SENDABLE = [ "image/png", "image/jpeg", "image/webp", "image/gif" ]

export async function prepare(file, maxBytes) {
  const sendable = SENDABLE.includes(file.type)
  let bitmap
  try {
    bitmap = await createImageBitmap(file)
  } catch {
    if (sendable && file.size <= maxBytes) return file
    throw new Error(`This browser can't open ${label(file)}. Send it from Safari or your phone, or save it as a JPEG or PNG first.`)
  }
  const scale = Math.min(1, MAX_SIDE / Math.max(bitmap.width, bitmap.height))
  if (scale === 1 && sendable && file.size <= maxBytes) {
    bitmap.close()
    return file
  }
  const canvas = document.createElement("canvas")
  canvas.width = Math.round(bitmap.width * scale)
  canvas.height = Math.round(bitmap.height * scale)
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close()
  const tries = [ ...(file.type === "image/png" ? [ [ "image/png" ] ] : []), [ "image/jpeg", 0.9 ], [ "image/jpeg", 0.75 ] ]
  for (const [ type, quality ] of tries) {
    const blob = await new Promise(resolve => canvas.toBlob(resolve, type, quality))
    if (blob && blob.size <= maxBytes) return new File([ blob ], renamed(file.name, type), { type })
  }
  throw new Error(`${file.name || "That picture"} is too large to send, even made smaller.`)
}

const label = file => {
  const kind = file.type.replace("image/", "").toUpperCase() || "that picture"
  return file.name ? `${file.name} (${kind})` : kind
}

const renamed = (name, type) => `${(name || "picture").replace(/\.[^.]+$/, "")}.${type === "image/png" ? "png" : "jpg"}`
