//
//  IVL10n.h
//  whaminsta
//
//  Localisation de l'interface du tweak. Chaque chaîne visible est résolue par
//  clé sémantique ; la langue cible est déterminée automatiquement à partir de
//  la langue de l'APP (override par conteneur si posé, sinon langue système du
//  téléphone, sinon repli FR->EN). Toute clé sans traduction retombe sur le
//  français (source), jamais sur una clé brute ou un trou.
//
//  Usage: label.text = IVLL(@"menu.creer_conteneur", @"Créer un conteneur");
//  Le 2e argument (français) sert de source ET de repli.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Retourne la traduction d'une clé dans la langue de l'app, sinon la source FR.
FOUNDATION_EXPORT NSString *IVLL(NSString *key, NSString *fallbackFR);

/// Langue cible courante (BCP-47, exemple «fr», «en», «es»…) — utile pour logs.
FOUNDATION_EXPORT NSString *IVLCurrentLanguage(void);

/// Force une langue cible explicitement (utilisé par les écrans de test / défaut
/// «système»). Passez nil pour revenir à la détection automatique.
FOUNDATION_EXPORT void IVLSetOverrideLanguage(NSString *_Nullable lang);

NS_ASSUME_NONNULL_END
