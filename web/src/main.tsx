import '@fontsource/jetbrains-mono/latin-400.css'
import '@fontsource/jetbrains-mono/latin-500.css'
import '@fontsource/jetbrains-mono/latin-600.css'
import 'subsetted-fonts/MiSans-VF/MiSans-VF.css'
import './styles/index.css'
import './i18n'

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider } from 'react-router-dom'
import { ThemeProvider } from './lib/theme'
import { AuthGate } from './app/AuthGate'
import { ErrorBoundary } from './app/ErrorBoundary'
import { Toaster } from './components/ds'
import { router } from './app/router'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <ErrorBoundary>
        <AuthGate>
          <RouterProvider router={router} />
        </AuthGate>
      </ErrorBoundary>
      <Toaster />
    </ThemeProvider>
  </StrictMode>,
)
