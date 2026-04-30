/// Secure Storage 与本地 DB 隔离字段共用：当前设备 Identity。
const String kRootIdIdentityStorageKey = 'rootid_identity_id';

/// 1.0 阶段绑定标志：'1' 代表已绑定，其他值或为空视为未绑定。
const String kRootIdIsBoundStorageKey = 'rootid_is_bound';

/// 1.0 阶段：用户是否查看并保存过 Identity Key。
const String kRootIdBackedUpKeyStorageKey = 'rootid_backed_up_key';
