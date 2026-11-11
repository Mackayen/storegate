export const TYPE = { receive: 'Receive', dispatch: 'Dispatch', transfer: 'Transfer' }

export const STATUS = {
  draft: 'Draft',
  pending_signoff: 'Awaiting sign off',
  signed_off: 'Signed off',
  rejected: 'Rejected',
  cancelled: 'Cancelled',
}

export const ROLES = ['admin', 'storeman', 'dispatch_manager', 'procurement', 'security', 'viewer']
export const STEP_ROLES = ['storeman', 'dispatch_manager', 'procurement', 'security', 'admin']

// Roles that may prepare and submit a movement. The database enforces the same list.
export const PREPARERS = ['admin', 'storeman', 'dispatch_manager', 'procurement']

// Roles that may flag, note, write off and replace units and add serial numbers. The database enforces it.
export const UNIT_MANAGERS = ['admin', 'storeman']

export const LEDGER_KIND = { movement: 'Movement', write_off: 'Written off', replacement: 'Replacement added' }

const ROLE_NAMES = {
  admin: 'Admin',
  storeman: 'Storeman',
  dispatch_manager: 'Dispatch manager',
  procurement: 'Procurement',
  security: 'Security',
  viewer: 'Viewer',
}
export const roleName = (r) => ROLE_NAMES[r] || r

export const fmtDate = (d) =>
  d ? new Date(d).toLocaleString('en-ZA', { dateStyle: 'medium', timeStyle: 'short' }) : ''

export const fmtQty = (q) => Number(q).toLocaleString('en-ZA', { maximumFractionDigits: 3 })

export const one = (x) => (Array.isArray(x) ? x[0] : x) || null

export const pinMessage = (code) =>
  ({
    wrong: 'Incorrect PIN.',
    locked: 'Too many attempts. Try again in 15 minutes, or ask an admin to reset your PIN.',
    not_set: 'Set your PIN on your profile first.',
  })[code] || 'Could not verify your PIN.'
