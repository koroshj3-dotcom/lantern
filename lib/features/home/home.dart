import 'package:lantern/core/common/app_text_styles.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/models/feature_flags.dart';
import 'package:lantern/core/utils/pro_utils.dart';
import 'package:lantern/features/action_mode/action_mode_widgets.dart';
import 'package:lantern/features/home/provider/app_event_notifier.dart';
import 'package:lantern/features/home/provider/app_setting_notifier.dart';
import 'package:lantern/features/home/provider/feature_flag_notifier.dart';
import 'package:lantern/features/home/provider/home_notifier.dart';
import 'package:lantern/features/home/pro_renewal_popup.dart';
import 'package:lantern/features/home/provider/radiance_settings_providers.dart';
import 'package:lantern/features/home/vpn_tab.dart';
import 'package:lantern/features/setting/referral_reward_dialog.dart';
import 'package:lantern/features/action_mode/provider/share_notifier.dart';
import 'package:lantern/features/action_mode/provider/action_mode_tab_visible_notifier.dart';
import 'package:lantern/features/action_mode/action_mode.dart';
import 'package:lantern/features/vpn/provider/available_servers_notifier.dart';
import 'package:lantern/features/vpn/provider/vpn_notifier.dart';

import '../../core/common/common.dart';

/// Root tab shell hosting the VPN and Unbounded tabs. Tab strip lives in
/// the AppBar so the chrome (Lantern logo + settings menu + account
/// actions) is shared across tabs and lines up with the Figma spec at
/// figma.com/design/hNlyYToB5TnX9SDBFDYJTq?node-id=2403-19287.
///
/// Tab labels carry a small dot indicator that turns green when the
/// matching feature is active (VPN: connected; Unbounded: peer share
/// on) and grey otherwise — also per spec.
@RoutePage(name: 'Home')
class Home extends HookConsumerWidget {
  const Home({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Congratulate the user once per converted referral, whenever fresh
    // user data lands (first load or later refreshes). listenManual (not
    // ref.listen) because the subscription must outlive a rebuild and is
    // torn down explicitly; the empty dep list keeps it to one
    // subscription for the widget's lifetime rather than one per build.
    useEffect(() {
      final sub = ref.listenManual(homeProvider, fireImmediately: true, (
        previous,
        next,
      ) {
        final user = next.value;
        if (user == null) return;
        if (!ref.read(appSettingProvider).onboardingCompleted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!context.mounted) return;
          await checkAndShowReferralReward(context, user);
          // Day-of renewal popup غیرفعال شد
          // if (!context.mounted) return;
          // await checkAndShowProRenewalPopup(context, ref);
        });
      });
      return sub.close;
    }, const []);

    final tabController = useTabController(initialLength: 2);
    // Tell the Action Mode globe whether its tab is on screen so it can mute
    // its \~60fps sphere re-projection while the user is on the VPN tab
    // (the globe keeps itself alive across tab switches). The globe
    // lives in tab index 1, so it should animate whenever any part of it
    // is on screen — including mid-swipe. animation.value is the
    // fractional tab position (0.0 = VPN fully shown, 1.0 = Unbounded
    // fully shown), so > 0 means the Unbounded tab is at least partly
    // revealed. (indexIsChanging only covers tap/animateTo, not a finger
    // drag, so it would freeze the globe during a swipe in.)
    //
    // The same listener drives the app bar wordmark, which swaps with the tab.
    final onUnboundedTab = useState(false);
    useEffect(() {
      void sync() {
        final pos =
            tabController.animation?.value ?? tabController.index.toDouble();
        ref.read(actionModeTabVisibleProvider.notifier).set(pos > 0.0);
        // Halfway through the swipe, so the title swaps once rather than
        // flickering per frame.
        onUnboundedTab.value = pos >= 0.5;
      }

      tabController.addListener(sync);
      // Deferred: on first mount this effect body runs inside Home.build, and
      // sync writes to a provider, which Riverpod rejects during a build.
      // Later invocations come from the controller's animation ticks, which
      // are already outside the build phase.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        sync();
      });
      return () => tabController.removeListener(sync);
    }, [tabController]);
    final isUserPro = ref.watch(isUserProProvider);
    final userLoggedIn = ref.watch(
      appSettingProvider.select((s) => s.userLoggedIn),
    );
    final unboundedHidden = ref.watch(
      appSettingProvider.select((s) => s.unboundedHidden),
    );
    final featureFlag = ref.watch(featureFlagProvider);
    // Server-side gate for the whole Unbounded UI surface. Censored
    // regions get the flag off, so the tab, strip, and any auto-enable
    // hook disappear. The user's own "Hide Unbounded tab" toggle still
    // wins on top of this for non-censored users who want it hidden.
    final unboundedAvailable = featureFlag.getBool(FeatureFlag.unbounded);
    final showUnboundedTab = unboundedAvailable && !unboundedHidden;
    useEffect(() {
      if (!showUnboundedTab) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) tabController.index = 0;
        });
      }
      return null;
    }, [showUnboundedTab]);
    final vpnStatus = ref.watch(vpnProvider);
    final shareActive = ref.watch(shareProvider.select((s) => s.active));

    // First-frame side effects: kick off server fetch, gate onboarding,
    // macOS sysext dialog. Lifted unchanged from the old Home body so
    // app-launch behaviour stays the same after the tab refactor.
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(availableServersProvider);
        final appSetting = ref.read(appSettingProvider);
        final appSettingNotifier = ref.read(appSettingProvider.notifier);
        if (!appSetting.onboardingCompleted) {
          appLogger.info(
            "User has not completed onboarding, navigating to Onboarding Screen",
          );
          appRouter.push(const Onboarding());
          return;
        }
        if (PlatformUtils.isMacOS) {
          appLogger.info(
            "App Setting - showSplashScreen: ${appSetting.showSplashScreen}",
          );
          if (appSetting.showSplashScreen) {
            appLogger.info("Showing System Extension Dialog");
            appRouter.push(const MacOSExtensionDialog());
            appLogger.info("Setting showSplashScreen to false");
            appSettingNotifier.setSplashScreen(false);
          }
        }
      });
      return null;
    }, const []);

    // Telemetry consent dialog — fires once per app session after the
    // first successful connection, gated on the metrics + traces
    // feature flags. Preserved from the old Home behaviour.
    useEffect(() {
      final appSetting = ref.read(appSettingProvider);
      if (appSetting.successfulConnection) {
        if (!appSetting.telemetryDialogDismissed &&
            (featureFlag.getBool(FeatureFlag.metrics) &&
                featureFlag.getBool(FeatureFlag.traces))) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showHelpLanternDialog(context, ref);
            ref.read(appSettingProvider.notifier).setShowTelemetryDialog(true);
          });
        }
      }
      return null;
    }, [featureFlag]);

    ref.read(appEventProvider);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!context.mounted) return;
        if (!unboundedAvailable) return;
        await ref.read(shareProvider.notifier).syncFromBackend(ref);
        if (!context.mounted) return;
        final appSetting = ref.read(appSettingProvider);
        if (appSetting.unboundedHidden) return;
        if (!appSetting.onboardingCompleted) return;
        if (!appSetting.unboundedAutoEnable) return;
        final share = ref.read(shareProvider);
        if (share.active || share.probing) return;
        ref.read(shareProvider.notifier).autoStart(ref);
      });
      return null;
    }, [unboundedAvailable]);

    ref.listen<VPNStatus>(vpnProvider, (prev, next) {
      if (prev == next) return;
      if (next != VPNStatus.connected) return;
      if (!unboundedAvailable) return;
      final appSetting = ref.read(appSettingProvider);
      if (appSetting.unboundedHidden) return;
      if (!appSetting.unboundedAutoEnable) return;
      final share = ref.read(shareProvider);
      if (share.active || share.probing) return;
      ref.read(shareProvider.notifier).autoStart(ref);
    });

    return Scaffold(
      key: const Key('home.screen'),
      appBar: AppBar(
        title: showUnboundedTab && onUnboundedTab.value
            ? Text(
                'unbounded'.i18n,
                style: Theme.of(context).textTheme.titleLarge,
              )
            : LanternLogo(isPro: isUserPro, color: context.textPrimary),
        backgroundColor: context.bgElevated,
        elevation: 5,
        leading: IconButton(
          key: const Key('home.menu_button'),
          tooltip: 'settings'.i18n,
          onPressed: () {
            appRouter.push(Setting());
          },
          icon: const AppImage(path: AppImagePaths.menu),
        ),
        actions: [
          // دکمه Sign In حذف شد
          // فقط اگر کاربر Pro باشه، آیکون اکانت نشون داده می‌شه
          if (isUserPro)
            AppIconButton(
              path: AppImagePaths.accountCircle,
              onPressed: () async {
                final localUser = ref.read(homeProvider).value;
                final userSignedIn = ref.read(appSettingProvider).userLoggedIn;
                await openAccountOrProAccountSetup(
                  context: context,
                  user: localUser,
                  userLoggedIn: userSignedIn,
                );
              },
            ),
        ],
        bottom: !showUnboundedTab || PlatformUtils.isMobile
            ? null
            : PreferredSize(
                preferredSize: Size.fromHeight(
                  ActionModeNavigation.desktopHeight(context),
                ),
                child: ActionModeNavigation(
                  selectedIndex: onUnboundedTab.value ? 1 : 0,
                  onSelected: tabController.animateTo,
                  vpnActive: vpnStatus == VPNStatus.connected,
                  actionActive: shareActive,
                  desktop: true,
                ),
              ),
      ),
      body: !showUnboundedTab
          ? const VpnTab()
          : TabBarView(
              controller: tabController,
              children: const [VpnTab(), ActionModeTab()],
            ),
      bottomNavigationBar: !showUnboundedTab || !PlatformUtils.isMobile
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: ActionModeNavigation(
                selectedIndex: onUnboundedTab.value ? 1 : 0,
                vpnActive: vpnStatus == VPNStatus.connected,
                actionActive: shareActive,
                onSelected: tabController.animateTo,
                desktop: false,
              ),
            ),
    );
  }
}

void _showHelpLanternDialog(BuildContext context, WidgetRef ref) {
  final textTheme = Theme.of(context).textTheme;
  AppDialog.customDialog(
    context: context,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 24),
        const AppImage(path: AppImagePaths.assessment),
        const SizedBox(height: 24),
        Text(
          'help_improve_lantern'.i18n,
          style: textTheme.headlineSmall!.copyWith(color: context.textPrimary),
        ),
        SizedBox(height: defaultSize),
        Text(
          'share_anonymous_usage_data'.i18n,
          style: textTheme.bodyMedium!.copyWith(color: context.textSecondary),
        ),
        SizedBox(height: defaultSize),
        Text(
          'data_we_collect'.i18n,
          style: AppTextStyles.bodyMediumBold.copyWith(
            color: context.textSecondary,
          ),
        ),
        SizedBox(height: defaultSize),
        Text(
          'you_can_change_anytime'.i18n,
          style: textTheme.bodyMedium!.copyWith(color: context.textSecondary),
        ),
      ],
    ),
    action: [
      AppTextButton(
        label: 'dont_allow'.i18n,
        textColor: context.textDisabled,
        onPressed: () {
          context.pop();
          ref.read(radianceSettingsProvider.notifier).setTelemetry(false);
        },
      ),
      AppTextButton(
        label: 'allow'.i18n,
        textColor: AppColors.blue6,
        onPressed: () {
          context.pop();
          ref.read(radianceSettingsProvider.notifier).setTelemetry(true);
        },
      ),
    ],
  );
}
