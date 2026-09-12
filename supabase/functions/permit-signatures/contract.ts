export const encodeBase64 = (bytes: Uint8Array) => {
  let output = '';
  for (let index = 0; index < bytes.length; index += 0x8000) {
    output += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(output);
};

export const protectedRenditionPayload = (bytes: Uint8Array) => ({
  mimeType: 'image/png',
  protectedBase64: encodeBase64(bytes),
  watermark: 'SMARTRESERVE • PROTECTED USER COPY',
});
