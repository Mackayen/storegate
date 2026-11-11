import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AuthProvider, useAuth } from './auth.jsx'
import Layout from './components/Layout.jsx'
import Login from './pages/Login.jsx'
import Dashboard from './pages/Dashboard.jsx'
import Movements from './pages/Movements.jsx'
import NewMovement from './pages/NewMovement.jsx'
import MovementDetail from './pages/MovementDetail.jsx'
import DeliveryNote from './pages/DeliveryNote.jsx'
import GatePass from './pages/GatePass.jsx'
import Gate from './pages/Gate.jsx'
import Search from './pages/Search.jsx'
import UnitDetail from './pages/UnitDetail.jsx'
import Ledger from './pages/Ledger.jsx'
import Notifications from './pages/Notifications.jsx'
import Profile from './pages/Profile.jsx'
import Admin from './pages/Admin.jsx'
import { PREPARERS } from './fmt.js'

// The role checks here only decide what to show. The database enforces the real rules.
function Guard({ roles, children }) {
  const { session, profile, loading } = useAuth()
  if (loading) return <p className="center">Loading…</p>
  if (!session || !profile) return <Navigate to="/login" replace />
  if (roles && !roles.includes(profile.role)) return <Navigate to="/" replace />
  return children
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route
            element={
              <Guard>
                <Layout />
              </Guard>
            }
          >
            <Route index element={<Dashboard />} />
            <Route path="movements" element={<Movements />} />
            <Route
              path="movements/new"
              element={
                <Guard roles={PREPARERS}>
                  <NewMovement />
                </Guard>
              }
            />
            <Route
              path="movements/:id/edit"
              element={
                <Guard roles={PREPARERS}>
                  <NewMovement />
                </Guard>
              }
            />
            <Route path="movements/:id" element={<MovementDetail />} />
            <Route path="movements/:id/delivery-note" element={<DeliveryNote />} />
            <Route path="movements/:id/gate-pass" element={<GatePass />} />
            <Route
              path="gate"
              element={
                <Guard roles={['admin', 'security']}>
                  <Gate />
                </Guard>
              }
            />
            <Route path="search" element={<Search />} />
            <Route path="units/:id" element={<UnitDetail />} />
            <Route path="ledger" element={<Ledger />} />
            <Route path="notifications" element={<Notifications />} />
            <Route path="profile" element={<Profile />} />
            <Route
              path="admin"
              element={
                <Guard roles={['admin']}>
                  <Admin />
                </Guard>
              }
            />
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}
