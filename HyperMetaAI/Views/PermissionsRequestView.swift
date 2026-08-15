/*
 * Permissions Request View
 * 应用启动时的权限请求界面
 */

import SwiftUI

struct PermissionsRequestView: View {
    @StateObject private var permissionsManager = PermissionsManager.shared
    @State private var isRequesting = false
    @State private var showSettings = false
    let onComplete: (Bool) -> Void

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [AppColors.primary.opacity(0.1), AppColors.secondary.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: AppSpacing.xl) {
                Spacer()

                // Icon
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 80))
                    .foregroundColor(AppColors.primary)

                // Title
                VStack(spacing: AppSpacing.sm) {
                    Text("permissions.required".localized)
                        .font(AppTypography.title)
                        .foregroundColor(AppColors.textPrimary)

                    Text("permissions.intro".localized)
                        .font(AppTypography.body)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xl)
                }

                // Permissions List
                VStack(spacing: AppSpacing.md) {
                    PermissionRow(
                        icon: "mic.fill",
                        title: "permissions.microphone".localized,
                        description: "permissions.microphone.desc".localized
                    )

                    PermissionRow(
                        icon: "photo.fill",
                        title: "permissions.photos".localized,
                        description: "permissions.photos.desc".localized
                    )
                }
                .padding(.horizontal, AppSpacing.xl)

                Spacer()

                // Request Button
                VStack(spacing: AppSpacing.md) {
                    if isRequesting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(1.5)
                    } else if showSettings {
                        VStack(spacing: AppSpacing.sm) {
                            Text("permissions.partial".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(.red)

                            Button {
                                permissionsManager.openSettings()
                            } label: {
                                HStack {
                                    Image(systemName: "gear")
                                    Text("permissions.openSettings".localized)
                                        .font(AppTypography.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppSpacing.md)
                                .background(AppColors.primary)
                                .foregroundColor(.white)
                                .cornerRadius(AppCornerRadius.lg)
                            }

                            Button("permissions.continueLimited".localized) {
                                onComplete(false)
                            }
                            .font(AppTypography.body)
                            .foregroundColor(AppColors.textSecondary)
                        }
                    } else {
                        Button {
                            requestPermissions()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("permissions.grant".localized)
                                    .font(AppTypography.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.md)
                            .background(AppColors.primary)
                            .foregroundColor(.white)
                            .cornerRadius(AppCornerRadius.lg)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.bottom, AppSpacing.xl)
            }
        }
        .onAppear {
            // 检查是否已有权限
            if permissionsManager.checkAllPermissions() {
                onComplete(true)
            }
        }
    }

    private func requestPermissions() {
        isRequesting = true

        permissionsManager.requestAllPermissions { allGranted in
            isRequesting = false

            if allGranted {
                // 所有权限已授予，继续
                onComplete(true)
            } else {
                // 部分权限未授予，显示设置按钮
                showSettings = true
            }
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(AppColors.primary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)

                Text(description)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }

            Spacer()
        }
        .padding(AppSpacing.md)
        .background(Color.white)
        .cornerRadius(AppCornerRadius.md)
        .shadow(color: AppShadow.small(), radius: 5, x: 0, y: 2)
    }
}

#Preview("Permissions") {
    PermissionsRequestView(onComplete: { _ in })
}
