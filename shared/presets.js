import { BASE_INSTRUCTION } from './instruction.js';

export const PRESETS = {
  // The measured default — see instruction.js for why this exact string.
  clean: BASE_INSTRUCTION,
  verbatim: "Add correct punctuation and capitalization to this transcript. Do not remove or reword anything else. Return only the corrected text.",
  bullets: "Rewrite this dictation as a concise bulleted list of the distinct points made. Use '- ' for each bullet. Return only the list.",
  email: "Rewrite this dictation as a clear, professional email body. Keep it concise and preserve every point the speaker made. Do not invent a greeting or signature. Return only the email body.",
};
