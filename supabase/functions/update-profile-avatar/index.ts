import { createClient } from "npm:@supabase/supabase-js@2"

type AvatarMetadata = {
  avatar_storage_path: string | null
  avatar_mime_type: string | null
  avatar_updated_at: string | null
}

const AVATAR_BUCKET = "avatars"
const SIGNED_URL_EXPIRES_SECONDS = 3600
const MAX_AVATAR_BYTES = 2 * 1024 * 1024

Deno.serve(async (req) => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

    if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: `Bearer ${accessToken}`,
        },
      },
    })
    const adminClient = createClient(supabaseUrl, serviceRoleKey)

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser()

    if (userError || !user) {
      return jsonResponse(
        {
          error: "Invalid JWT",
          details: userError?.message ?? null,
        },
        401
      )
    }

    if (user.is_anonymous === true) {
      return jsonResponse(
        {
          error: "Avatar customization requires a signed-in account",
          code: "signed_in_account_required",
        },
        403
      )
    }

    switch (req.method) {
      case "GET":
        return await getAvatarResponse(adminClient, user.id)
      case "POST":
        return await updateAvatarResponse({
          req,
          adminClient,
          userID: user.id,
        })
      case "DELETE":
        return await deleteAvatarResponse(adminClient, user.id)
      default:
        return jsonResponse({ error: "Method Not Allowed" }, 405)
    }
  } catch (error) {
    return jsonResponse(
      {
        error: "Unexpected server error",
        details: error instanceof Error ? error.message : String(error),
      },
      500
    )
  }
})

async function getAvatarResponse(adminClient: any, userID: string): Promise<Response> {
  const profile = await fetchAvatarMetadata(adminClient, userID)
  if (!profile) {
    return jsonResponse({ error: "Profile not found" }, 404)
  }

  const signedURL = await createAvatarSignedURL(adminClient, profile.avatar_storage_path)
  return jsonResponse({
    avatarStoragePath: profile.avatar_storage_path,
    avatarMimeType: profile.avatar_mime_type,
    avatarUpdatedAt: profile.avatar_updated_at,
    signedURL,
    signedURLExpiresIn: signedURL ? SIGNED_URL_EXPIRES_SECONDS : null,
  })
}

async function updateAvatarResponse(args: {
  req: Request
  adminClient: any
  userID: string
}): Promise<Response> {
  const profile = await fetchAvatarMetadata(args.adminClient, args.userID)
  if (!profile) {
    return jsonResponse({ error: "Profile not found" }, 404)
  }

  const body = await args.req.json()
  const parsedImage = parseAvatarImage(body)
  if (!parsedImage.ok) {
    return jsonResponse({ error: parsedImage.error, code: parsedImage.code }, 400)
  }

  const avatarPath = `${args.userID}/avatar-${Date.now()}.${parsedImage.extension}`
  const { error: uploadError } = await args.adminClient.storage
    .from(AVATAR_BUCKET)
    .upload(avatarPath, parsedImage.bytes, {
      contentType: parsedImage.contentType,
      upsert: false,
    })

  if (uploadError) {
    return jsonResponse(
      {
        error: "Failed to upload avatar",
        details: uploadError.message,
      },
      500
    )
  }

  const updatedAt = new Date().toISOString()
  const { error: updateError } = await args.adminClient
    .from("profiles")
    .update({
      avatar_storage_path: avatarPath,
      avatar_mime_type: parsedImage.contentType,
      avatar_updated_at: updatedAt,
    })
    .eq("id", args.userID)

  if (updateError) {
    await removeAvatarPathQuietly(args.adminClient, avatarPath)
    return jsonResponse(
      {
        error: "Failed to update profile avatar",
        details: updateError.message,
      },
      500
    )
  }

  if (profile.avatar_storage_path && profile.avatar_storage_path !== avatarPath) {
    await removeAvatarPathQuietly(args.adminClient, profile.avatar_storage_path)
  }

  const signedURL = await createAvatarSignedURL(args.adminClient, avatarPath)
  return jsonResponse({
    success: true,
    avatarStoragePath: avatarPath,
    avatarMimeType: parsedImage.contentType,
    avatarUpdatedAt: updatedAt,
    signedURL,
    signedURLExpiresIn: signedURL ? SIGNED_URL_EXPIRES_SECONDS : null,
  })
}

async function deleteAvatarResponse(adminClient: any, userID: string): Promise<Response> {
  const profile = await fetchAvatarMetadata(adminClient, userID)
  if (!profile) {
    return jsonResponse({ error: "Profile not found" }, 404)
  }

  const { error: updateError } = await adminClient
    .from("profiles")
    .update({
      avatar_storage_path: null,
      avatar_mime_type: null,
      avatar_updated_at: null,
    })
    .eq("id", userID)

  if (updateError) {
    return jsonResponse(
      {
        error: "Failed to clear profile avatar",
        details: updateError.message,
      },
      500
    )
  }

  if (profile.avatar_storage_path) {
    await removeAvatarPathQuietly(adminClient, profile.avatar_storage_path)
  }

  return jsonResponse({
    success: true,
    avatarStoragePath: null,
    avatarMimeType: null,
    avatarUpdatedAt: null,
    signedURL: null,
    signedURLExpiresIn: null,
  })
}

async function fetchAvatarMetadata(adminClient: any, userID: string): Promise<AvatarMetadata | null> {
  const { data, error } = await adminClient
    .from("profiles")
    .select("avatar_storage_path, avatar_mime_type, avatar_updated_at")
    .eq("id", userID)
    .maybeSingle()

  if (error) {
    throw new Error(`Failed to load profile avatar: ${error.message}`)
  }

  return data as AvatarMetadata | null
}

async function createAvatarSignedURL(
  adminClient: any,
  avatarPath: string | null
): Promise<string | null> {
  if (!avatarPath) {
    return null
  }

  const { data, error } = await adminClient.storage
    .from(AVATAR_BUCKET)
    .createSignedUrl(avatarPath, SIGNED_URL_EXPIRES_SECONDS)

  if (error) {
    throw new Error(`Failed to create avatar signed URL: ${error.message}`)
  }

  return data?.signedUrl ?? null
}

function parseAvatarImage(body: unknown):
  | {
      ok: true
      bytes: Uint8Array
      contentType: string
      extension: string
    }
  | { ok: false; error: string; code: string } {
  const payload = typeof body === "object" && body !== null ? body as Record<string, unknown> : {}
  const rawImageBase64 = typeof payload.imageBase64 === "string" ? payload.imageBase64.trim() : ""
  const rawContentType = typeof payload.contentType === "string" ? payload.contentType.trim() : ""
  const dataURLMatch = rawImageBase64.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/)
  const contentTypeFromDataURL = dataURLMatch?.[1]?.toLowerCase() ?? ""
  const imageBase64 = (dataURLMatch?.[2] ?? rawImageBase64).replace(/\s+/g, "")
  const requestedContentType = (rawContentType || contentTypeFromDataURL).toLowerCase()

  if (!imageBase64) {
    return {
      ok: false,
      error: "imageBase64 is required",
      code: "missing_image",
    }
  }

  let bytes: Uint8Array
  try {
    bytes = decodeBase64(imageBase64)
  } catch {
    return {
      ok: false,
      error: "Invalid imageBase64",
      code: "invalid_image_base64",
    }
  }

  if (bytes.byteLength <= 0 || bytes.byteLength > MAX_AVATAR_BYTES) {
    return {
      ok: false,
      error: "Avatar image must be 2MB or smaller",
      code: "avatar_too_large",
    }
  }

  const detectedContentType = detectImageContentType(bytes)
  if (!detectedContentType) {
    return {
      ok: false,
      error: "Unsupported avatar image type",
      code: "unsupported_image_type",
    }
  }

  if (requestedContentType && requestedContentType !== detectedContentType) {
    return {
      ok: false,
      error: "Avatar content type does not match image data",
      code: "content_type_mismatch",
    }
  }

  return {
    ok: true,
    bytes,
    contentType: detectedContentType,
    extension: extensionForContentType(detectedContentType),
  }
}

function detectImageContentType(bytes: Uint8Array): string | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg"
  }

  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return "image/png"
  }

  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return "image/webp"
  }

  return null
}

function extensionForContentType(contentType: string): string {
  switch (contentType) {
    case "image/png":
      return "png"
    case "image/webp":
      return "webp"
    case "image/jpeg":
    default:
      return "jpg"
  }
}

function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

async function removeAvatarPathQuietly(adminClient: any, path: string): Promise<void> {
  try {
    await adminClient.storage.from(AVATAR_BUCKET).remove([path])
  } catch (error) {
    console.error(
      "[update-profile-avatar]",
      JSON.stringify({
        code: "avatar_storage_cleanup_failed",
        internalError: error instanceof Error ? error.message : String(error),
        path,
        at: new Date().toISOString(),
      })
    )
  }
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}
