//! Key derivation.

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use secrecy::ExposeSecret;
use std::convert::TryInto;
use std::ffi::{CStr, CString};
use std::mem::ManuallyDrop;
use std::os::raw::c_char;
use std::slice;

use transparent::address::TransparentAddress;
use zcash_address::{
    ConversionError, ToAddress, TryFromAddress, ZcashAddress,
    unified::{self, Container, Encoding, Item as _},
};
use zcash_client_backend::{
    address::UnifiedAddress,
    encoding::{decode_extended_full_viewing_key, decode_extended_spending_key},
    keys::{
        Era, UnifiedAddressRequest, UnifiedFullViewingKey, UnifiedIncomingViewingKey,
        UnifiedSpendingKey,
    },
};
use zcash_keys::constants::{
    hrp_sapling_extended_full_viewing_key, hrp_sapling_extended_spending_key,
};
use zcash_protocol::consensus::{NetworkConstants, NetworkType, Parameters};
use zip32::{ChainCode, ChildIndex, DiversifierIndex, arbitrary, registered::PathElement};

use crate::{decode_usk, ffi, free_ptr_from_vec, parse_network, unwrap_exc_or, unwrap_exc_or_null};

enum AddressType {
    Sprout,
    P2pkh,
    P2sh,
    Sapling,
    Unified,
    Tex,
}

struct AddressMetadata {
    network: NetworkType,
    addr_type: AddressType,
}

#[derive(Debug)]
enum Void {}

impl TryFromAddress for AddressMetadata {
    /// This instance produces no errors.
    type Error = Void;

    fn try_from_sprout(
        network: NetworkType,
        _data: [u8; 64],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(AddressMetadata {
            network,
            addr_type: AddressType::Sprout,
        })
    }

    fn try_from_sapling(
        network: NetworkType,
        _data: [u8; 43],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(AddressMetadata {
            network,
            addr_type: AddressType::Sapling,
        })
    }

    fn try_from_unified(
        network: NetworkType,
        _data: unified::Address,
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(AddressMetadata {
            network,
            addr_type: AddressType::Unified,
        })
    }

    fn try_from_transparent_p2pkh(
        network: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(AddressMetadata {
            network,
            addr_type: AddressType::P2pkh,
        })
    }

    fn try_from_transparent_p2sh(
        network: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(AddressMetadata {
            network,
            addr_type: AddressType::P2sh,
        })
    }

    fn try_from_tex(
        network: NetworkType,
        _data: [u8; 20],
    ) -> Result<Self, ConversionError<Self::Error>> {
        Ok(AddressMetadata {
            network,
            addr_type: AddressType::Tex,
        })
    }
}

fn zip32_account_index(account: i32) -> anyhow::Result<zip32::AccountId> {
    u32::try_from(account)
        .map_err(|_| ())
        .and_then(|id| zip32::AccountId::try_from(id).map_err(|_| ()))
        .map_err(|_| anyhow!("Invalid account ID"))
}

/// Returns the network type and address kind for the given address string,
/// if the address is a valid Zcash address.
///
/// Address kind codes are as follows:
/// * p2pkh: 0
/// * p2sh: 1
/// * sapling: 2
/// * unified: 3
/// * tex: 4
///
/// # Safety
///
/// - `address` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `address` must not be mutated for the duration of the function call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_get_address_metadata(
    address: *const c_char,
    network_id_ret: *mut u32,
    addr_kind_ret: *mut u32,
) -> bool {
    let res = catch_panic(|| {
        let addr = unsafe { CStr::from_ptr(address).to_str()? };
        let zaddr = ZcashAddress::try_from_encoded(addr)?;

        // The following .unwrap is safe because address type detection
        // cannot fail for valid ZcashAddress values.
        let addr_meta: AddressMetadata = zaddr.convert().unwrap();
        unsafe {
            *network_id_ret = match addr_meta.network {
                NetworkType::Main => 1,
                NetworkType::Test => 0,
                NetworkType::Regtest => {
                    return Err(anyhow!("Regtest addresses are not supported."));
                }
            };

            *addr_kind_ret = match addr_meta.addr_type {
                AddressType::P2pkh => 0,
                AddressType::P2sh => 1,
                AddressType::Sapling => 2,
                AddressType::Unified => 3,
                AddressType::Tex => 4,
                AddressType::Sprout => {
                    return Err(anyhow!("Sprout addresses are not supported."));
                }
            };
        }

        Ok(true)
    });
    unwrap_exc_or(res, false)
}

/// Extracts the typecodes of the receivers within the given Unified Address.
///
/// Returns a pointer to a slice of typecodes. `len_ret` is set to the length of the
/// slice.
///
/// See the following sections of ZIP 316 for details on how to interpret typecodes:
/// - [List of known typecodes](https://zips.z.cash/zip-0316#encoding-of-unified-addresses)
/// - [Adding new types](https://zips.z.cash/zip-0316#adding-new-types)
/// - [Metadata Items](https://zips.z.cash/zip-0316#metadata-items)
///
/// # Safety
///
/// - `ua` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `ua` must not be mutated for the duration of the function call.
/// - Call [`zcashlc_free_typecodes`] to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_get_typecodes_for_unified_address_receivers(
    ua: *const c_char,
    len_ret: *mut usize,
) -> *mut u32 {
    let res = catch_panic(|| {
        let ua_str = unsafe { CStr::from_ptr(ua).to_str()? };

        let (_, _, ua) = unified::Address::decode(ua_str)
            .map_err(|e| anyhow!("Invalid Unified Address: {}", e))?;

        let typecodes = ua
            .items()
            .into_iter()
            .map(|receiver| match receiver {
                unified::Receiver::P2pkh(_) => unified::Typecode::P2PKH,
                unified::Receiver::P2sh(_) => unified::Typecode::P2SH,
                unified::Receiver::Sapling(_) => unified::Typecode::SAPLING,
                unified::Receiver::Orchard(_) => unified::Typecode::ORCHARD,
                unified::Receiver::Unknown { typecode, .. } => {
                    unified::Typecode::Data(unified::DataTypecode::Unknown(typecode))
                }
            })
            .map(u32::from)
            .collect::<Vec<_>>();

        let mut typecodes = ManuallyDrop::new(typecodes.into_boxed_slice());
        let (ptr, len) = (typecodes.as_mut_ptr(), typecodes.len());

        unsafe { *len_ret = len };
        Ok(ptr)
    });
    unwrap_exc_or_null(res)
}

/// Frees a list of typecodes previously obtained from the FFI.
///
/// # Safety
///
/// - `data` and `len` must have been obtained from
///   [`zcashlc_get_typecodes_for_unified_address_receivers`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_typecodes(data: *mut u32, len: usize) {
    free_ptr_from_vec(data, len);
}

/// Returns true when the provided key decodes to a valid Sapling extended spending key for the
/// specified network, false in any other case.
///
/// # Safety
///
/// - `extsk` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `extsk` must not be mutated for the duration of the function call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_is_valid_sapling_extended_spending_key(
    extsk: *const c_char,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let extsk = unsafe { CStr::from_ptr(extsk).to_str()? };

        Ok(decode_extended_spending_key(
            hrp_sapling_extended_spending_key(network.network_type()),
            extsk,
        )
        .is_ok())
    });
    unwrap_exc_or(res, false)
}

/// Returns true when the provided key decodes to a valid Sapling extended full viewing key for the
/// specified network, false in any other case.
///
/// # Safety
///
/// - `key` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `key` must not be mutated for the duration of the function call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_is_valid_viewing_key(key: *const c_char, network_id: u32) -> bool {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let vkstr = unsafe { CStr::from_ptr(key).to_str()? };

        Ok(decode_extended_full_viewing_key(
            hrp_sapling_extended_full_viewing_key(network.network_type()),
            vkstr,
        )
        .is_ok())
    });
    unwrap_exc_or(res, false)
}

/// Returns true when the provided key decodes to a valid unified full viewing key for the
/// specified network, false in any other case.
///
/// # Safety
///
/// - `ufvk` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `ufvk` must not be mutated for the duration of the
///   function call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_is_valid_unified_full_viewing_key(
    ufvk: *const c_char,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let ufvkstr = unsafe { CStr::from_ptr(ufvk).to_str()? };

        Ok(UnifiedFullViewingKey::decode(&network, ufvkstr).is_ok())
    });
    unwrap_exc_or(res, false)
}

bitflags::bitflags! {
    /// The kinds of item a unified full viewing key carries, as reported over the FFI by
    /// [`zcashlc_describe_unified_full_viewing_key`]. The values match the receiver flags used
    /// elsewhere in this crate where they overlap.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) struct UfvkComponentFlags: i32 {
        /// The key has a transparent P2PKH item.
        const P2PKH = 0b0000_0001;
        /// The key has a transparent P2SH viewing key item.
        const P2SH = 0b0000_0010;
        /// The key has a Sapling item.
        const SAPLING = 0b0000_0100;
        /// The key has an Orchard item.
        const ORCHARD = 0b0000_1000;
        /// The key has at least one data item of a typecode this library does not recognize.
        const UNKNOWN = 0b0001_0000;
    }
}

/// Decodes `encoding` as a unified full viewing key for `network`, ignoring surrounding
/// whitespace, so that every caller accepts exactly the same keys. The error names the step that
/// failed and never contains any part of the input.
///
/// The steps are those of `UnifiedFullViewingKey::decode`, taken one by one so that the
/// container is returned too: it also yields the unknown items, which `UnifiedFullViewingKey`
/// does not expose.
pub(crate) fn decode_ufvk(
    network: &impl Parameters,
    encoding: &str,
) -> anyhow::Result<(unified::Ufvk, UnifiedFullViewingKey)> {
    let (found, _revision, container) = unified::Ufvk::decode(encoding.trim())
        .map_err(|_| anyhow!("the value is not a unified full viewing key"))?;
    if found != network.network_type() {
        return Err(anyhow!(
            "the unified full viewing key is for another network"
        ));
    }
    let ufvk = UnifiedFullViewingKey::parse(&container)
        .map_err(|_| anyhow!("the unified full viewing key holds an invalid item"))?;
    Ok((container, ufvk))
}

/// The components of `encoding` when it is a unified full viewing key for `network`, `None`
/// otherwise. Surrounding whitespace is ignored. Never echoes the input.
pub(crate) fn describe_ufvk(
    network: &impl Parameters,
    encoding: &str,
) -> Option<UfvkComponentFlags> {
    let (container, ufvk) = decode_ufvk(network, encoding).ok()?;

    let mut flags = UfvkComponentFlags::empty();
    flags.set(UfvkComponentFlags::P2PKH, ufvk.p2pkh().is_some());
    flags.set(UfvkComponentFlags::P2SH, ufvk.p2sh().is_some());
    flags.set(UfvkComponentFlags::SAPLING, ufvk.has_sapling());
    flags.set(UfvkComponentFlags::ORCHARD, ufvk.has_orchard());
    flags.set(
        UfvkComponentFlags::UNKNOWN,
        container
            .items_as_parsed()
            .iter()
            .any(|item| matches!(item, unified::Uitem::Data(unified::Fvk::Unknown { .. }))),
    );
    Some(flags)
}

/// Reports which items the provided unified full viewing key carries, for the specified network.
/// Whitespace around the key is ignored.
///
/// Returns:
/// - a bitmask of the items the key carries: `1` for P2PKH, `2` for P2SH, `4` for Sapling, `8`
///   for Orchard, and `16` when it carries at least one item of a typecode this library does
///   not recognize;
/// - `-1` when `ufvk` is not a unified full viewing key for `network_id`. This is not an error,
///   and no last error is set;
/// - `-2` on an internal failure: a null `ufvk`, a `ufvk` that is not UTF-8, an invalid
///   `network_id`, or a panic. The last error is set, and never contains any part of the key.
///
/// # Safety
///
/// - `ufvk` must be null or must point to a null-terminated string.
/// - The memory referenced by `ufvk` must not be mutated for the duration of the
///   function call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_describe_unified_full_viewing_key(
    ufvk: *const c_char,
    network_id: u32,
) -> i32 {
    let res = catch_panic(|| {
        if ufvk.is_null() {
            return Err(anyhow!("no unified full viewing key was supplied"));
        }
        let network = parse_network(network_id)?;
        let encoding = unsafe { CStr::from_ptr(ufvk) }
            .to_str()
            .map_err(|_| anyhow!("the unified full viewing key is not UTF-8"))?;
        Ok(describe_ufvk(&network, encoding).map_or(-1, |flags| flags.bits()))
    });
    unwrap_exc_or(res, -2)
}

/// Returns true when the provided key encoding is a valid unified incoming viewing key for the
/// given network, false in any other case.
///
/// # Safety
///
/// - `uivk` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `uivk` must not be mutated for the duration of the
///   function call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_is_valid_unified_incoming_viewing_key(
    uivk: *const c_char,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let uivkstr = unsafe { CStr::from_ptr(uivk).to_str()? };

        Ok(UnifiedIncomingViewingKey::decode(&network, uivkstr).is_ok())
    });
    unwrap_exc_or(res, false)
}

/// Derives and returns a unified spending key from the given seed for the given account ID.
///
/// Returns the binary encoding of the spending key. The caller should manage the memory of (and
/// store, if necessary) the returned spending key in a secure fashion.
///
/// # Safety
///
/// - `seed` must be non-null and valid for reads for `seed_len` bytes.
/// - The memory referenced by `seed` must not be mutated for the duration of the function call.
/// - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
///   of `pointer::offset`.
/// - Call `zcashlc_free_binary_key` to free the memory associated with the returned pointer when
///   you are finished using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_derive_spending_key(
    seed: *const u8,
    seed_len: usize,
    hd_account_index: i32,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let seed = unsafe { slice::from_raw_parts(seed, seed_len) };
        let account = zip32_account_index(hd_account_index)?;

        UnifiedSpendingKey::from_seed(&network, seed, account)
            .map_err(|e| anyhow!("error generating unified spending key from seed: {:?}", e))
            .map(move |usk| {
                let encoded = usk.to_bytes(Era::Orchard);
                ffi::BoxedSlice::some(encoded.expose_secret().to_vec())
            })
    });
    unwrap_exc_or_null(res)
}

/// Obtains the unified full viewing key for the given binary-encoded unified spending key
/// and returns the resulting encoded UFVK string. `usk_ptr` should point to an array of `usk_len`
/// bytes containing a unified spending key encoded as returned from the `zcashlc_create_account`
/// or `zcashlc_derive_spending_key` functions.
///
/// # Safety
///
/// - `usk_ptr` must be non-null and must point to an array of `usk_len` bytes.
/// - The memory referenced by `usk_ptr` must not be mutated for the duration of the function call.
/// - The total size `usk_len` must be no larger than `isize::MAX`. See the safety documentation
///   of `pointer::offset`.
/// - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
///   when you are done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_spending_key_to_full_viewing_key(
    usk_ptr: *const u8,
    usk_len: usize,
    network_id: u32,
) -> *mut c_char {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        unsafe { decode_usk(usk_ptr, usk_len) }.and_then(|usk| {
            let ufvk = usk
                .to_unified_full_viewing_key()
                .encode(&network)
                .map_err(|e| anyhow!("Error encoding unified full viewing key: {e}"))?;
            Ok(CString::new(ufvk).unwrap().into_raw())
        })
    });
    unwrap_exc_or_null(res)
}

struct UnifiedAddressParser(UnifiedAddress);

impl zcash_address::TryFromAddress for UnifiedAddressParser {
    type Error = anyhow::Error;

    fn try_from_unified(
        _net: NetworkType,
        data: zcash_address::unified::Address,
    ) -> Result<Self, zcash_address::ConversionError<Self::Error>> {
        data.try_into()
            .map(UnifiedAddressParser)
            .map_err(|e| anyhow!("Invalid Unified Address: {}", e).into())
    }
}

/// Derives a unified address address for the provided UFVK, along with the diversifier at which it
/// was derived; this may not be equal to the provided diversifier index if no valid Sapling
/// address could be derived at that index. If the `diversifier_index_bytes` parameter is null, the
/// default address for the UFVK is returned.
///
/// # Safety
///
/// - `ufvk` must be non-null and must point to a null-terminated UTF-8 string.
/// - `diversifier_index_bytes must either be null or be valid for reads for 11 bytes and have an
///   alignment of `1`.
/// - Call [`zcashlc_free_ffi_address`] to free the memory associated with the returned pointer
///   when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_derive_address_from_ufvk(
    network_id: u32,
    ufvk: *const c_char,
    diversifier_index_bytes: *const u8,
) -> *mut ffi::Address {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let ufvk_str = unsafe { CStr::from_ptr(ufvk).to_str()? };
        // The message is fixed on purpose: the value is a viewing key, and neither it nor the
        // decoder's description of it may reach error text that ends up in app logs.
        let ufvk = UnifiedFullViewingKey::decode(&network, ufvk_str)
            .map_err(|_| anyhow!("The value did not decode as a valid UFVK"))?;

        let (ua, di) = if diversifier_index_bytes.is_null() {
            ufvk.default_address(UnifiedAddressRequest::AllAvailableKeys)
        } else {
            let j = DiversifierIndex::from(<[u8; 11]>::try_from(unsafe {
                slice::from_raw_parts(diversifier_index_bytes, 11)
            })?);
            ufvk.find_address(j, UnifiedAddressRequest::AllAvailableKeys)
        }?;

        Ok(Box::into_raw(Box::new(ffi::Address::new(&network, ua, di))))
    });
    unwrap_exc_or_null(res)
}

/// Derives a unified address address for the provided UIVK, along with the diversifier at which it
/// was derived; this may not be equal to the provided diversifier index if no valid Sapling
/// address could be derived at that index. If the `diversifier_index_bytes` parameter is null, the
/// default address for the UIVK is returned.
///
/// # Safety
///
/// - `uivk` must be non-null and must point to a null-terminated UTF-8 string.
/// - `diversifier_index_bytes must either be null or be valid for reads for 11 bytes and have an
///   alignment of `1`.
/// - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
///   when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_derive_address_from_uivk(
    network_id: u32,
    uivk: *const c_char,
    diversifier_index_bytes: *const u8,
) -> *mut ffi::Address {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let uivk_str = unsafe { CStr::from_ptr(uivk).to_str()? };
        // The message is fixed on purpose: the value is a viewing key, and neither it nor the
        // decoder's description of it may reach error text that ends up in app logs.
        let uivk = UnifiedIncomingViewingKey::decode(&network, uivk_str)
            .map_err(|_| anyhow!("The value did not decode as a valid UIVK"))?;

        let (ua, di) = if diversifier_index_bytes.is_null() {
            uivk.default_address(UnifiedAddressRequest::AllAvailableKeys)
        } else {
            let j = DiversifierIndex::from(<[u8; 11]>::try_from(unsafe {
                slice::from_raw_parts(diversifier_index_bytes, 11)
            })?);
            uivk.find_address(j, UnifiedAddressRequest::AllAvailableKeys)
        }?;

        Ok(Box::into_raw(Box::new(ffi::Address::new(&network, ua, di))))
    });
    unwrap_exc_or_null(res)
}

/// Returns the transparent receiver within the given Unified Address, if any.
///
/// # Safety
///
/// - `ua` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `ua` must not be mutated for the duration of the function call.
/// - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
///   when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_get_transparent_receiver_for_unified_address(
    ua: *const c_char,
) -> *mut c_char {
    let res = catch_panic(|| {
        let ua_str = unsafe { CStr::from_ptr(ua).to_str()? };

        let (network, ua) = match ZcashAddress::try_from_encoded(ua_str) {
            Ok(addr) => addr
                .convert::<(_, UnifiedAddressParser)>()
                .map_err(|e| anyhow!("Not a Unified Address: {}", e)),
            Err(e) => return Err(anyhow!("Invalid Zcash address: {}", e)),
        }?;

        if let Some(taddr) = ua.0.transparent() {
            let taddr = match taddr {
                TransparentAddress::PublicKeyHash(data) => {
                    ZcashAddress::from_transparent_p2pkh(network, *data)
                }
                TransparentAddress::ScriptHash(data) => {
                    ZcashAddress::from_transparent_p2sh(network, *data)
                }
            };

            Ok(CString::new(taddr.encode())?.into_raw())
        } else {
            Err(anyhow!(
                "Unified Address doesn't contain a transparent receiver"
            ))
        }
    });
    unwrap_exc_or_null(res)
}

/// Returns the Sapling receiver within the given Unified Address, if any.
///
/// # Safety
///
/// - `ua` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `ua` must not be mutated for the duration of the function call.
/// - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
///   when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_get_sapling_receiver_for_unified_address(
    ua: *const c_char,
) -> *mut c_char {
    let res = catch_panic(|| {
        let ua_str = unsafe { CStr::from_ptr(ua).to_str()? };

        let (network, ua) = match ZcashAddress::try_from_encoded(ua_str) {
            Ok(addr) => addr
                .convert::<(_, UnifiedAddressParser)>()
                .map_err(|e| anyhow!("Not a Unified Address: {}", e)),
            Err(e) => return Err(anyhow!("Invalid Zcash address: {}", e)),
        }?;

        if let Some(addr) = ua.0.sapling() {
            Ok(
                CString::new(ZcashAddress::from_sapling(network, addr.to_bytes()).encode())?
                    .into_raw(),
            )
        } else {
            Err(anyhow!(
                "Unified Address doesn't contain a Sapling receiver"
            ))
        }
    });
    unwrap_exc_or_null(res)
}

/// Constructs an ffi::AccountMetadataKey from its parts.
///
/// # Safety
///
/// - `sk` must be non-null and valid for reads for 32 bytes, and it must have an alignment of `1`.
/// - The memory referenced by `sk` must not be mutated for the duration of the function call.
/// - `chain_code` must be non-null and valid for reads for 32 bytes, and it must have an alignment
///   of `1`.
/// - The memory referenced by `chain_code` must not be mutated for the duration of the function
///   call.
/// - Call [`zcashlc_free_account_metadata_key`] to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_account_metadata_key_from_parts(
    sk: *const u8,
    chain_code: *const u8,
) -> *mut ffi::AccountMetadataKey {
    let res = catch_panic(|| {
        let sk = unsafe { slice::from_raw_parts(sk, 32) }.try_into().unwrap();
        let chain_code = ChainCode::new(
            unsafe { slice::from_raw_parts(chain_code, 32) }
                .try_into()
                .unwrap(),
        );

        let key = zip32::registered::SecretKey::from_parts(sk, chain_code);

        Ok(ffi::AccountMetadataKey::new(key))
    });
    unwrap_exc_or_null(res)
}

/// Derives a ZIP 325 Account Metadata Key from the given seed.
///
/// # Safety
///
/// - `seed` must be non-null and valid for reads for `seed_len` bytes.
/// - The memory referenced by `seed` must not be mutated for the duration of the function call.
/// - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
///   of `pointer::offset`.
/// - Call [`zcashlc_free_account_metadata_key`] to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_derive_account_metadata_key(
    seed: *const u8,
    seed_len: usize,
    account: i32,
    network_id: u32,
) -> *mut ffi::AccountMetadataKey {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let seed = unsafe { slice::from_raw_parts(seed, seed_len) };
        let account = zip32_account_index(account)?;

        let key = zip32::registered::SecretKey::from_subpath(
            b"MetadataKeys",
            seed,
            325,
            &[
                PathElement::new(ChildIndex::hardened(network.coin_type()), &[]),
                PathElement::new(ChildIndex::hardened(account.into()), &[]),
            ],
        )?;

        Ok(ffi::AccountMetadataKey::new(key))
    });
    unwrap_exc_or_null(res)
}

/// Derives a metadata key for private use from a ZIP 325 Account Metadata Key.
///
/// - `ufvk` is the external UFVK for which a metadata key is required, or `null` if the
///   metadata key is "inherent" (for the same account as the Account Metadata Key).
/// - `private_use_subject` is a globally unique non-empty sequence of at most 252 bytes
///   that identifies the desired private-use context.
///
/// If `ufvk` is null, this function will return a single 32-byte metadata key.
///
/// If `ufvk` is non-null, this function will return one metadata key for every FVK item
/// contained within the UFVK, in preference order. As UFVKs may in general change over
/// time (due to the inclusion of new higher-preference FVK items, or removal of older
/// deprecated FVK items), private usage of these keys should always follow preference
/// order:
/// - For encryption-like private usage, the first key in the array should always be
///   used, and all other keys ignored.
/// - For decryption-like private usage, each key in the array should be tried in turn
///   until metadata can be recovered, and then the metadata should be re-encrypted
///   under the first key.
///
/// # Safety
///
/// - `account_metadata_key` must be non-null and must point to a struct having the layout
///   of [`ffi::AccountMetadataKey`].
/// - The memory referenced by `account_metadata_key` must not be mutated for the duration
///   of the function call.
/// - If `ufvk` is non-null, it must point to a null-terminated UTF-8 string.
/// - `private_use_subject` must be non-null and valid for reads for `private_use_subject_len`
///   bytes.
/// - The memory referenced by `private_use_subject` must not be mutated for the duration
///   of the function call.
/// - The total size `private_use_subject_len` must be no larger than `isize::MAX`. See
///   the safety documentation of `pointer::offset`.
/// - Call `zcashlc_free_symmetric_keys` to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_derive_private_use_metadata_key(
    account_metadata_key: *const ffi::AccountMetadataKey,
    ufvk: *const c_char,
    private_use_subject: *const u8,
    private_use_subject_len: usize,
    network_id: u32,
) -> *mut ffi::SymmetricKeys {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let account_metadata_key = unsafe { account_metadata_key.as_ref() }
            .ok_or(anyhow!("An AccountMetadataKey is required"))?;
        let ufvk_str = (!ufvk.is_null())
            .then(|| unsafe { CStr::from_ptr(ufvk) }.to_str())
            .transpose()?;
        let private_use_subject =
            unsafe { slice::from_raw_parts(private_use_subject, private_use_subject_len) };

        let private_use_keys = match ufvk_str {
            // For the inherent subtree, there is only ever one key.
            None => vec![
                account_metadata_key
                    .inner
                    .derive_child_with_tag(ChildIndex::hardened(0), &[])
                    .derive_child_with_tag(ChildIndex::PRIVATE_USE, private_use_subject),
            ],
            // For the external subtree, we derive keys from the UFVK's items.
            Some(ufvk_string) => {
                let (net, _, ufvk) =
                    unified::Ufvk::decode(ufvk_string).map_err(|e| anyhow!("{e}"))?;
                let expected_net = network.network_type();
                if net != expected_net {
                    return Err(anyhow!(
                        "UFVK is for network {:?} but we expected {:?}",
                        net,
                        expected_net,
                    ));
                }

                // Any metadata should always be associated with the key derived from the
                // most preferred FVK item. However, we don't know which FVK items the
                // UFVK contained the last time we were asked to derive keys. So we derive
                // every key and return them to the caller in preference order. If the
                // caller finds data associated with an older FVK item, they will migrate
                // it to the first key we return.
                ufvk.items()
                    .into_iter()
                    .map(|fvk_item| {
                        account_metadata_key
                            .inner
                            .derive_child_with_tag(ChildIndex::hardened(1), &[])
                            .derive_child_with_tag(
                                ChildIndex::hardened(0),
                                &fvk_item.typed_encoding(),
                            )
                            .derive_child_with_tag(ChildIndex::PRIVATE_USE, private_use_subject)
                    })
                    .collect()
            }
        };

        Ok(ffi::SymmetricKeys::ptr_from_vec(
            private_use_keys
                .into_iter()
                .map(|txid| *txid.data())
                .collect(),
        ))
    });
    unwrap_exc_or_null(res)
}

/// Derives and returns a ZIP 32 Arbitrary Key from the given seed at the "wallet level", i.e.
/// directly from the seed with no ZIP 32 path applied.
///
/// The resulting key will be the same across all networks (Zcash mainnet, Zcash testnet, OtherCoin
/// mainnet, and so on). You can think of it as a context-specific seed fingerprint that can be used
/// as (static) key material.
///
/// `context_string` is a globally-unique non-empty sequence of at most 252 bytes that identifies
/// the desired context.
///
/// # Safety
///
/// - `context_string` must be non-null and valid for reads for `context_string_len` bytes.
/// - The memory referenced by `context_string` must not be mutated for the duration of the function
///   call.
/// - The total size `context_string_len` must be no larger than `isize::MAX`. See the safety
///   documentation of `pointer::offset`.
/// - `seed` must be non-null and valid for reads for `seed_len` bytes.
/// - The memory referenced by `seed` must not be mutated for the duration of the function call.
/// - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
///   of `pointer::offset`.
/// - Call `zcashlc_free_boxed_slice` to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_derive_arbitrary_wallet_key(
    context_string: *const u8,
    context_string_len: usize,
    seed: *const u8,
    seed_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let context_string = unsafe { slice::from_raw_parts(context_string, context_string_len) };
        let seed = unsafe { slice::from_raw_parts(seed, seed_len) };

        let key = arbitrary::SecretKey::from_path(context_string, seed, &[]);

        Ok(ffi::BoxedSlice::some(key.data().to_vec()))
    });
    unwrap_exc_or_null(res)
}

/// Derives and returns a ZIP 32 Arbitrary Key from the given seed at the account level.
///
/// `context_string` is a globally-unique non-empty sequence of at most 252 bytes that identifies
/// the desired context.
///
/// # Safety
///
/// - `context_string` must be non-null and valid for reads for `context_string_len` bytes.
/// - The memory referenced by `context_string` must not be mutated for the duration of the function
///   call.
/// - The total size `context_string_len` must be no larger than `isize::MAX`. See the safety
///   documentation of `pointer::offset`.
/// - `seed` must be non-null and valid for reads for `seed_len` bytes`.
/// - The memory referenced by `seed` must not be mutated for the duration of the function call.
/// - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
///   of `pointer::offset`.
/// - Call `zcashlc_free_boxed_slice` to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_derive_arbitrary_account_key(
    context_string: *const u8,
    context_string_len: usize,
    seed: *const u8,
    seed_len: usize,
    account: i32,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let context_string = unsafe { slice::from_raw_parts(context_string, context_string_len) };
        let seed = unsafe { slice::from_raw_parts(seed, seed_len) };
        let account = zip32_account_index(account)?;

        let key = arbitrary::SecretKey::from_path(
            context_string,
            seed,
            &[
                ChildIndex::hardened(32),
                ChildIndex::hardened(network.coin_type()),
                ChildIndex::hardened(account.into()),
            ],
        );

        Ok(ffi::BoxedSlice::some(key.data().to_vec()))
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_protocol::consensus::{MAIN_NETWORK, TEST_NETWORK};

    /// Opens a fresh wallet database at `path` and creates one seed-derived account in it,
    /// returning its uuid bytes — enough for a test to call a real `zcashlc_*` function against
    /// an account that exists.
    fn fixture_account(path: &std::path::Path) -> [u8; 16] {
        use zcash_client_backend::data_api::{AccountBirthday, WalletWrite};
        use zcash_client_backend::proto::service::TreeState;
        use zcash_client_sqlite::WalletDb;
        use zcash_client_sqlite::util::SystemClock;
        use zcash_client_sqlite::wallet::init::init_wallet_db;

        let mut db = WalletDb::for_path(path, MAIN_NETWORK, SystemClock, crate::system_rng())
            .expect("the wallet database must open");
        init_wallet_db(&mut db, None).expect("initializes the wallet schema");
        let seed = secrecy::SecretVec::new(vec![7u8; 32]);
        let treestate = TreeState {
            // `from_treestate` requires a valid 32-byte block hash; everything else can stay
            // at the proto defaults (height 0, empty tree frontiers).
            hash: "00".repeat(32),
            ..TreeState::default()
        };
        let birthday = AccountBirthday::from_treestate(treestate, None)
            .expect("the fixture treestate must convert to a birthday");
        let (account, _usk) = db
            .create_account("fixture", &seed, &birthday, None)
            .expect("account creation must succeed");
        // `get_next_available_address` needs a chain tip to select confirmed diversifiers
        // from; any height past the account's birthday does.
        db.update_chain_tip(zcash_protocol::consensus::BlockHeight::from_u32(2_000_000))
            .expect("sets the chain tip");
        account.expose_uuid().into_bytes()
    }

    /// The unified address the FFI gives to Swift keeps its transparent receiver, and decodes at
    /// revision 0.
    #[test]
    fn next_available_address_keeps_its_transparent_receiver_at_revision_0() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("wallet.sqlite");
        let account_uuid = fixture_account(&path);
        let path_str = path.to_str().expect("utf8 path");
        let path_bytes = path_str.as_bytes();

        let address_ptr = unsafe {
            crate::zcashlc_get_next_available_address(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account_uuid.as_ptr(),
                crate::NETWORK_ID_MAINNET,
                0b0000_1101, // P2PKH | SAPLING | ORCHARD
            )
        };
        if address_ptr.is_null() {
            let len = crate::zcashlc_last_error_length();
            let mut buf = vec![0u8; len as usize];
            unsafe { crate::zcashlc_error_message_utf8(buf.as_mut_ptr() as *mut i8, len) };
            panic!(
                "the FFI call must succeed: {}",
                String::from_utf8_lossy(&buf)
            );
        }
        let address_str = unsafe { CStr::from_ptr(address_ptr) }
            .to_str()
            .expect("utf8")
            .to_string();
        unsafe { crate::zcashlc_string_free(address_ptr) };

        let (_, revision, address) =
            unified::Address::decode(&address_str).expect("the address decodes");
        assert_eq!(revision, unified::Revision::R0, "must decode at revision 0");
        assert!(
            address
                .items()
                .iter()
                .any(|r| matches!(r, unified::Receiver::P2pkh(_))),
            "the transparent receiver must survive: {address_str}"
        );
    }

    /// A UFVK, a UIVK and a UA for a seed-derived key encode at revision 0 with every item, and
    /// each decodes back to the same value.
    fn assert_revision_0_round_trip(
        network: &impl Parameters,
        ua_prefix: &str,
        ufvk_prefix: &str,
        uivk_prefix: &str,
    ) {
        let usk = UnifiedSpendingKey::from_seed(network, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let ufvk = usk.to_unified_full_viewing_key();
        let uivk = ufvk.to_unified_incoming_viewing_key();
        let (ua, _) = ufvk
            .default_address(UnifiedAddressRequest::AllAvailableKeys)
            .expect("an address derives");

        let ufvk_str = ufvk.encode(network).unwrap();
        let uivk_str = uivk.encode(network).unwrap();
        let ua_str = ua.encode(network);

        assert!(
            ufvk_str.starts_with(ufvk_prefix),
            "{ufvk_str} must start with {ufvk_prefix}"
        );
        assert!(
            uivk_str.starts_with(uivk_prefix),
            "{uivk_str} must start with {uivk_prefix}"
        );
        assert!(
            ua_str.starts_with(ua_prefix),
            "{ua_str} must start with {ua_prefix}"
        );

        let decoded_ufvk = UnifiedFullViewingKey::decode(network, &ufvk_str).expect("ufvk decodes");
        assert_eq!(decoded_ufvk.encode(network).unwrap(), ufvk_str);

        let decoded_uivk =
            UnifiedIncomingViewingKey::decode(network, &uivk_str).expect("uivk decodes");
        assert_eq!(decoded_uivk.encode(network).unwrap(), uivk_str);

        let (_, _, raw_ua) = unified::Address::decode(&ua_str).expect("ua decodes");
        assert!(
            raw_ua
                .items()
                .iter()
                .any(|r| matches!(r, unified::Receiver::P2pkh(_))),
            "the transparent receiver must survive: {ua_str}"
        );
        let decoded_ua = UnifiedAddress::try_from(raw_ua).expect("converts to a UnifiedAddress");
        assert_eq!(decoded_ua.encode(network), ua_str);
    }

    #[test]
    fn ufvk_uivk_and_ua_encode_at_revision_0_and_round_trip_on_mainnet() {
        assert_revision_0_round_trip(&MAIN_NETWORK, "u1", "uview1", "uivk1");
    }

    #[test]
    fn ufvk_uivk_and_ua_encode_at_revision_0_and_round_trip_on_testnet() {
        assert_revision_0_round_trip(&TEST_NETWORK, "utest1", "uviewtest1", "uivktest1");
    }

    /// `zcashlc_spending_key_to_full_viewing_key` returns the revision 0 UFVK of the key.
    #[test]
    fn spending_key_to_full_viewing_key_returns_revision_0() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let usk_bytes = usk.to_bytes(Era::Orchard);
        let usk_bytes = usk_bytes.expose_secret();

        let ufvk_ptr = unsafe {
            zcashlc_spending_key_to_full_viewing_key(
                usk_bytes.as_ptr(),
                usk_bytes.len(),
                crate::NETWORK_ID_MAINNET,
            )
        };
        assert!(!ufvk_ptr.is_null(), "the FFI call must succeed");
        let ufvk_str = unsafe { CStr::from_ptr(ufvk_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        unsafe { crate::zcashlc_string_free(ufvk_ptr) };

        let (_, revision, _) = unified::Ufvk::decode(&ufvk_str).unwrap();
        assert_eq!(revision, unified::Revision::R0, "{ufvk_str}");
    }

    /// Three rows of `librustzcash`'s own unified-address test vectors — the
    /// `TEST_VECTORS` table in `zcash_address`'s
    /// `src/kind/unified/address/test_vectors.rs` (sourced from
    /// `zcash/zcash-test-vectors`'s `unified_address.py`), revision 0, mainnet:
    /// a p2pkh+sapling address, a p2pkh+orchard address, and a
    /// p2pkh+sapling+orchard address.
    #[test]
    fn upstream_revision_0_vectors_round_trip_byte_for_byte() {
        let vectors = [
            "u1l8xunezsvhq8fgzfl7404m450nwnd76zshscn6nfys7vyz2ywyh4cc5daaq0c7q2su5lqfh23sp7fkf3kt27ve5948mzpfdvckzaect2jtte308mkwlycj2u0eac077wu70vqcetkxf",
            "u1snf9yr883aj2hm8pksp9aymnqdwzy42rpzuffevj35hhxeckays5pcpeq7vy2mtgzlcuc4mnh9443qnuyje0yx6h59angywka4v2ap6kchh2j96ezf9w0c0auyz3wwts2lx5gmk2sk9",
            "u19mzuf4l37ny393m59v4mxx4t3uyxkh7qpqjdfvlfk9f504cv9w4fpl7cql0kqvssz8jay8mgl8lnrtvg6yzh9pranjj963acc3h2z2qt7007du0lsmdf862dyy40c3wmt0kq35k5z836tfljgzsqtdsccchayfjpygqzkx24l77ga3ngfgskqddyepz8we7ny4ggmt7q48cgvgu57mz",
        ];

        for vector in vectors {
            let (_, revision, raw) = unified::Address::decode(vector).expect("vector decodes");
            assert_eq!(
                revision,
                unified::Revision::R0,
                "upstream vector must be revision 0"
            );
            let ua = UnifiedAddress::try_from(raw).expect("converts to a UnifiedAddress");
            let re_encoded = ua.encode(&MAIN_NETWORK);
            assert_eq!(
                re_encoded, vector,
                "must reproduce the upstream vector exactly"
            );
        }
    }

    /// A transparent-only UFVK and a transparent-only unified address have no shielded item, so
    /// revision 0 cannot represent either (ZIP 316). They encode at revision 2.
    #[test]
    fn transparent_only_values_fall_back_to_revision_2_instead_of_erroring() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let ufvk = usk.to_unified_full_viewing_key();
        let (ua, _) = ufvk
            .default_address(UnifiedAddressRequest::AllAvailableKeys)
            .expect("an address derives");

        // A transparent-only UFVK built from the fixture key's own p2pkh item.
        let p2pkh_fvk_bytes: [u8; 65] = ufvk
            .p2pkh()
            .expect("the fixture key has a transparent item")
            .serialize()
            .try_into()
            .expect("an account public key is 65 bytes");
        let transparent_only_ufvk_str = unified::Ufvk::try_from_items(
            unified::Revision::R2,
            vec![unified::Uitem::Data(unified::Fvk::P2pkh(p2pkh_fvk_bytes))],
        )
        .expect("a single transparent item is valid at revision 2")
        .encode(&MAIN_NETWORK.network_type());
        let transparent_only_ufvk =
            UnifiedFullViewingKey::decode(&MAIN_NETWORK, &transparent_only_ufvk_str)
                .expect("the fixture string decodes");

        let encoded_ufvk = transparent_only_ufvk.encode(&MAIN_NETWORK).unwrap();
        assert_eq!(
            encoded_ufvk, transparent_only_ufvk_str,
            "a transparent-only UFVK must encode at revision 2"
        );

        // A transparent-only UA built from the fixture address's own receiver, plus an
        // optional metadata item to reach the F4Jumble minimum length. An unknown data item
        // would not do: revision 0 accepts a transparent receiver next to an unknown data item.
        let receiver_item = match ua
            .transparent()
            .expect("the fixture address has a transparent receiver")
        {
            TransparentAddress::PublicKeyHash(data) => unified::Receiver::P2pkh(*data),
            TransparentAddress::ScriptHash(data) => unified::Receiver::P2sh(*data),
        };
        let transparent_only_ua_str = unified::Address::try_from_items(
            unified::Revision::R2,
            vec![
                unified::Uitem::Data(receiver_item),
                unified::Uitem::Metadata(unified::MetadataItem::Unknown {
                    typecode: 0xc0,
                    data: vec![0u8; 20],
                }),
            ],
        )
        .expect("a transparent receiver plus padding is valid at revision 2")
        .encode(&MAIN_NETWORK.network_type());
        let (_, _, raw_ua) =
            unified::Address::decode(&transparent_only_ua_str).expect("the fixture string decodes");
        let transparent_only_ua =
            UnifiedAddress::try_from(raw_ua).expect("converts to a UnifiedAddress");

        let encoded_ua = transparent_only_ua.encode(&MAIN_NETWORK);
        assert_eq!(
            encoded_ua, transparent_only_ua_str,
            "a transparent-only address must encode at revision 2"
        );
    }

    /// Revision 0 rejects a container whose only data items are transparent. An unknown data
    /// item is not transparent, so an address with a transparent receiver and an unknown
    /// receiver, but no Orchard or Sapling receiver, encodes at revision 0.
    #[test]
    fn a_transparent_and_an_unknown_receiver_encode_at_revision_0() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let (ua, _) = usk
            .to_unified_full_viewing_key()
            .default_address(UnifiedAddressRequest::AllAvailableKeys)
            .expect("an address derives");
        let receiver_item = match ua
            .transparent()
            .expect("the fixture address has a transparent receiver")
        {
            TransparentAddress::PublicKeyHash(data) => unified::Receiver::P2pkh(*data),
            TransparentAddress::ScriptHash(data) => unified::Receiver::P2sh(*data),
        };
        let input = unified::Address::try_from_items(
            unified::Revision::R0,
            vec![
                unified::Uitem::Data(receiver_item),
                unified::Uitem::Data(unified::Receiver::Unknown {
                    typecode: 0xff00,
                    data: vec![0u8; 20],
                }),
            ],
        )
        .expect("a transparent receiver plus an unknown receiver is valid at revision 0")
        .encode(&MAIN_NETWORK.network_type());
        let (_, _, raw_ua) = unified::Address::decode(&input).expect("the fixture string decodes");
        let decoded = UnifiedAddress::try_from(raw_ua).expect("converts to a UnifiedAddress");

        assert_eq!(decoded.encode(&MAIN_NETWORK), input);
    }

    /// A data item of a typecode this crate does not interpret keeps its place at revision 0.
    #[test]
    fn an_unknown_item_keeps_its_place_at_revision_0() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let ufvk = usk.to_unified_full_viewing_key();
        let orchard_bytes = ufvk
            .orchard()
            .expect("the fixture key has an orchard item")
            .to_bytes();
        let sapling_bytes = ufvk
            .sapling()
            .expect("the fixture key has a sapling item")
            .to_bytes();

        let input = unified::Ufvk::try_from_items(
            unified::Revision::R0,
            vec![
                unified::Uitem::Data(unified::Fvk::Orchard(orchard_bytes)),
                unified::Uitem::Data(unified::Fvk::Sapling(sapling_bytes)),
                unified::Uitem::Data(unified::Fvk::Unknown {
                    typecode: 0xff00,
                    data: vec![1, 2, 3, 4],
                }),
            ],
        )
        .expect("a shielded item plus an unknown item is valid at revision 0")
        .encode(&MAIN_NETWORK.network_type());

        let decoded = UnifiedFullViewingKey::decode(&MAIN_NETWORK, &input)
            .expect("the fixture string decodes");
        let output = decoded.encode(&MAIN_NETWORK).unwrap();

        assert_eq!(output, input, "the unknown item must survive unchanged");
    }

    /// ZIP 316 gives typecode 0x01 no meaning in a revision 0 viewing key, so the decoder keeps
    /// such an item as an unknown item. The item stays at revision 0 with typecode 0x01. At
    /// revision 2, typecode 0x01 is a P2SH item, so a revision 2 string would not decode back.
    #[test]
    fn a_typecode_0x01_item_keeps_its_place_at_revision_0() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let ufvk = usk.to_unified_full_viewing_key();
        let orchard_bytes = ufvk
            .orchard()
            .expect("the fixture key has an orchard item")
            .to_bytes();

        let input = unified::Ufvk::try_from_items(
            unified::Revision::R0,
            vec![
                unified::Uitem::Data(unified::Fvk::Orchard(orchard_bytes)),
                unified::Uitem::Data(unified::Fvk::Unknown {
                    typecode: 0x01,
                    data: vec![1, 2, 3, 4],
                }),
            ],
        )
        .expect("a shielded item plus an unknown 0x01 item is valid at revision 0")
        .encode(&MAIN_NETWORK.network_type());

        let decoded = UnifiedFullViewingKey::decode(&MAIN_NETWORK, &input)
            .expect("the fixture string decodes");
        assert_eq!(decoded.encode(&MAIN_NETWORK).unwrap(), input);
    }

    /// A transparent-only UIVK has no shielded item, so revision 0 cannot represent it. It
    /// encodes at revision 2.
    #[test]
    fn transparent_only_uivk_falls_back_to_revision_2_instead_of_erroring() {
        use transparent::keys::IncomingViewingKey as _;

        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let uivk = usk
            .to_unified_full_viewing_key()
            .to_unified_incoming_viewing_key();

        // A transparent-only UIVK built from the fixture key's own p2pkh item.
        let p2pkh_ivk_bytes: [u8; 65] = uivk
            .p2pkh()
            .expect("the fixture key has a transparent item")
            .serialize()
            .try_into()
            .expect("an external ivk is 65 bytes");
        let transparent_only_uivk_str = unified::Uivk::try_from_items(
            unified::Revision::R2,
            vec![unified::Uitem::Data(unified::Ivk::P2pkh(p2pkh_ivk_bytes))],
        )
        .expect("a single transparent item is valid at revision 2")
        .encode(&MAIN_NETWORK.network_type());
        let transparent_only_uivk =
            UnifiedIncomingViewingKey::decode(&MAIN_NETWORK, &transparent_only_uivk_str)
                .expect("the fixture string decodes");

        assert_eq!(
            transparent_only_uivk.encode(&MAIN_NETWORK).unwrap(),
            transparent_only_uivk_str,
            "a transparent-only UIVK must encode at revision 2"
        );
    }

    /// A unified address with an expiry-height metadata item is a value revision 0 cannot
    /// hold. It encodes at revision 2 with the metadata and every receiver.
    #[test]
    fn ua_with_expiry_metadata_falls_back_to_revision_2_instead_of_dropping_it() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let ufvk = usk.to_unified_full_viewing_key();
        let (ua, _) = ufvk
            .default_address(UnifiedAddressRequest::AllAvailableKeys)
            .expect("an address derives");

        let orchard_bytes = ua
            .orchard()
            .expect("the fixture address has an orchard receiver")
            .to_raw_address_bytes();
        let sapling_bytes = ua
            .sapling()
            .expect("the fixture address has a sapling receiver")
            .to_bytes();
        let transparent_item = match ua
            .transparent()
            .expect("the fixture address has a transparent receiver")
        {
            TransparentAddress::PublicKeyHash(data) => unified::Receiver::P2pkh(*data),
            TransparentAddress::ScriptHash(data) => unified::Receiver::P2sh(*data),
        };

        let with_expiry_str = unified::Address::try_from_items(
            unified::Revision::R2,
            vec![
                unified::Uitem::Data(unified::Receiver::Orchard(orchard_bytes)),
                unified::Uitem::Data(unified::Receiver::Sapling(sapling_bytes)),
                unified::Uitem::Data(transparent_item),
                unified::Uitem::Metadata(unified::MetadataItem::ExpiryHeight(2_000_000)),
            ],
        )
        .expect("the fixture's receivers plus an expiry height item are valid at revision 2")
        .encode(&MAIN_NETWORK.network_type());
        let (_, _, raw_ua) =
            unified::Address::decode(&with_expiry_str).expect("the fixture string decodes");
        let ua_with_expiry =
            UnifiedAddress::try_from(raw_ua).expect("converts to a UnifiedAddress");

        assert_eq!(
            ua_with_expiry.encode(&MAIN_NETWORK),
            with_expiry_str,
            "an address with expiry metadata must encode at revision 2"
        );
    }

    /// A UFVK with an expiry-height metadata item is a value revision 0 cannot hold. It encodes
    /// at revision 2 with the metadata.
    #[test]
    fn ufvk_with_expiry_metadata_falls_back_to_revision_2_instead_of_dropping_it() {
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives");
        let ufvk = usk.to_unified_full_viewing_key();
        let orchard_bytes = ufvk
            .orchard()
            .expect("the fixture key has an orchard item")
            .to_bytes();
        let sapling_bytes = ufvk
            .sapling()
            .expect("the fixture key has a sapling item")
            .to_bytes();

        let with_expiry_str = unified::Ufvk::try_from_items(
            unified::Revision::R2,
            vec![
                unified::Uitem::Data(unified::Fvk::Orchard(orchard_bytes)),
                unified::Uitem::Data(unified::Fvk::Sapling(sapling_bytes)),
                unified::Uitem::Metadata(unified::MetadataItem::ExpiryHeight(2_000_000)),
            ],
        )
        .expect("a shielded item plus an expiry height item is valid at revision 2")
        .encode(&MAIN_NETWORK.network_type());
        let ufvk_with_expiry = UnifiedFullViewingKey::decode(&MAIN_NETWORK, &with_expiry_str)
            .expect("zcash_keys accepts a UFVK carrying expiry metadata");

        assert_eq!(
            ufvk_with_expiry.encode(&MAIN_NETWORK).unwrap(),
            with_expiry_str,
            "a UFVK with expiry metadata must encode at revision 2"
        );
    }

    /// A mainnet UFVK with a P2SH viewing-key item and an Orchard item: the first vector with a
    /// P2SH item (Orchard, no expiry) in `zcash_keys`'s
    /// `src/keys/test_vectors/unified_viewing_keys_r2.rs`, from `zcash/zcash-test-vectors`'s
    /// `unified_viewing_keys_r2.py`.
    const P2SH_ORCHARD_UFVK_VECTOR: &str = "uvf1td5cvtvcvlmxqgaxus3m2m745ykzk5gncx4z7x5zrk9l256qjfmfg6n8efrg0htq5sac4kg54aejsepkcl6hgaqyk6dlstk4fpnkmxjcvl72zh97r3fz7wa02wt4mmcayn6ukzck9d96tcqmkk2j5rzdr44f6haa9v7qzqsserruscf6lqum38xr8k84yesq8ecxa25aqg04uh3gweg8d25055v9z5u4c75mtt06g57eu8mq8eldg2gn9su23hkv0jrq7asc6tad5kaxs4r330uyf8qmydxkhe0nmtx26nux84sftau7072hp72qhfdzyhwu3ndhdq4glu8zjxp7srdaep9nn96swfl8td478n3jey0r73x5du50gjqr37ta39dpg25vkqw0q59pvfxp4xhl8392keskzl202njjeh677tphgcuayn09kl9vkxqkcy2pq7tar8vcjgewvem8hptycrd7v659lgzsnr85udpx7kv785m4a4259wr0snunfndya9x44m0zqt3py4x9md4vcdrj628qxmam6t836dp5zwsv744ay";

    /// A P2SH viewing-key item is revision-2-only (ZIP 316), so a UFVK with one encodes at
    /// revision 2.
    #[test]
    fn p2sh_ufvk_falls_back_to_revision_2_instead_of_erroring() {
        let p2sh_ufvk_str = P2SH_ORCHARD_UFVK_VECTOR;

        let decoded = UnifiedFullViewingKey::decode(&MAIN_NETWORK, p2sh_ufvk_str)
            .expect("the upstream vector decodes");

        assert_eq!(
            decoded.encode(&MAIN_NETWORK).unwrap(),
            p2sh_ufvk_str,
            "must reproduce the upstream vector exactly"
        );
    }

    /// The UIVK of the key above: a P2SH item, so it encodes at revision 2.
    #[test]
    fn p2sh_uivk_falls_back_to_revision_2_instead_of_erroring() {
        let p2sh_uivk_str = "uvi153t9c3gg9y02a7lwtku6pk9hqhz0mvxysnnr770usznsghqfjz69maurfgecxawspdcumw0j2arw7yms275rgs34v8y3trezdh78cl6vvqmypgqmnsqp34psk8420kndga6vpefj468pkfxdfyu4awum9g68fgm5vfszm6vv05z46e6f5r0vvvu2frzv969tgeuy5aes9ugd9jlut7n3ym69u6a3mjrrxsxdt9c5v78z5ze0ffm85ehsge480krnhw0r9v928qr7k5c5f6mht4f23fdk608zugpqfhmndlle35fd5qdew8le2taepl604fp6dd4w7tquydjtwzxs7c24smzccjqf6q5eljr6fwrlagyqwd5smz4rxsz5fz9kjnn2ce8xe3lwmm2dhd28cd2mnr85lnhe956tts4hse455m0kwt25n5029f29gchm6lpaz88mp3stqnk2e4s0u684zu6wl45mhhw2a540tyw5f25uz2ztsas9jjrsn";

        let decoded = UnifiedIncomingViewingKey::decode(&MAIN_NETWORK, p2sh_uivk_str)
            .expect("the upstream vector decodes");

        assert_eq!(
            decoded.encode(&MAIN_NETWORK).unwrap(),
            p2sh_uivk_str,
            "must reproduce the upstream vector exactly"
        );
    }

    /// The seed-derived key the description tests start from. It carries a P2PKH, a Sapling and
    /// an Orchard item.
    fn describe_test_key(network: &impl Parameters) -> UnifiedFullViewingKey {
        UnifiedSpendingKey::from_seed(network, &[7u8; 32], zip32::AccountId::ZERO)
            .expect("a spending key derives")
            .to_unified_full_viewing_key()
    }

    /// The encoding of [`describe_test_key`] for `network`.
    fn describe_test_ufvk(network: &impl Parameters) -> String {
        describe_test_key(network)
            .encode(network)
            .expect("the UFVK encodes")
    }

    /// The data items of the mainnet [`describe_test_key`]: Orchard, Sapling and P2PKH.
    fn describe_test_items() -> (unified::Fvk, unified::Fvk, unified::Fvk) {
        let key = describe_test_key(&MAIN_NETWORK);
        let orchard = unified::Fvk::Orchard(
            key.orchard()
                .expect("the test key has an Orchard item")
                .to_bytes(),
        );
        let sapling = unified::Fvk::Sapling(
            key.sapling()
                .expect("the test key has a Sapling item")
                .to_bytes(),
        );
        let p2pkh = unified::Fvk::P2pkh(
            key.p2pkh()
                .expect("the test key has a P2PKH item")
                .serialize()
                .try_into()
                .expect("an account public key is 65 bytes"),
        );
        (orchard, sapling, p2pkh)
    }

    /// Encodes a mainnet revision 0 UFVK holding `items`.
    fn ufvk_from_items(items: Vec<unified::Fvk>) -> String {
        unified::Ufvk::try_from_items(
            unified::Revision::R0,
            items.into_iter().map(unified::Uitem::Data).collect(),
        )
        .expect("the items form a valid revision 0 UFVK")
        .encode(&MAIN_NETWORK.network_type())
    }

    /// Calls [`zcashlc_describe_unified_full_viewing_key`] with `input`, after clearing the last
    /// error so that the caller can tell whether this call set one.
    fn describe(input: impl Into<Vec<u8>>, network_id: u32) -> i32 {
        let input = CString::new(input).expect("the input has no interior NUL");
        crate::zcashlc_clear_last_error();
        unsafe { zcashlc_describe_unified_full_viewing_key(input.as_ptr(), network_id) }
    }

    /// Asserts that the FFI reports `input` as not a UFVK for `network_id`: `-1`, which is not an
    /// error, so no last error is set.
    fn assert_not_a_ufvk(input: impl Into<Vec<u8>>, network_id: u32, case: &str) {
        assert_eq!(describe(input, network_id), -1, "{case}");
        assert_eq!(
            crate::zcashlc_last_error_length(),
            0,
            "{case} must not set a last error"
        );
    }

    /// The last error message set on this thread.
    fn last_error_message() -> String {
        let len = crate::zcashlc_last_error_length();
        assert!(len > 0, "a last error must be set");
        let mut buf = vec![0u8; len as usize];
        let written =
            unsafe { crate::zcashlc_error_message_utf8(buf.as_mut_ptr().cast::<c_char>(), len) };
        // A failed copy leaves the buffer zeroed, which would read as an empty message that
        // trivially contains no part of the key.
        assert_eq!(written, len, "the whole message must be copied");
        CStr::from_bytes_until_nul(&buf)
            .expect("the message is NUL-terminated")
            .to_string_lossy()
            .into_owned()
    }

    /// Asserts that `message` contains no 16-character slice of `input`, compared
    /// case-insensitively.
    fn assert_no_echo(message: &str, input: &str, case: &str) {
        let message = message.to_lowercase();
        let input: Vec<char> = input.to_lowercase().chars().collect();
        assert!(input.len() >= 16, "{case}: the input is too short to check");
        for (offset, window) in input.windows(16).enumerate() {
            let slice: String = window.iter().collect();
            assert!(
                !message.contains(&slice),
                "the error for {case} echoes the input at offset {offset}"
            );
        }
    }

    /// The flag values are the C contract of [`zcashlc_describe_unified_full_viewing_key`].
    #[test]
    fn describe_flag_values_match_the_ffi_contract() {
        assert_eq!(UfvkComponentFlags::P2PKH.bits(), 1);
        assert_eq!(UfvkComponentFlags::P2SH.bits(), 2);
        assert_eq!(UfvkComponentFlags::SAPLING.bits(), 4);
        assert_eq!(UfvkComponentFlags::ORCHARD.bits(), 8);
        assert_eq!(UfvkComponentFlags::UNKNOWN.bits(), 16);
    }

    /// A key derived from a seed carries a P2PKH, a Sapling and an Orchard item, on either
    /// network.
    #[test]
    fn describe_reports_every_component_of_a_seed_derived_key() {
        let every_component =
            (UfvkComponentFlags::P2PKH | UfvkComponentFlags::SAPLING | UfvkComponentFlags::ORCHARD)
                .bits();

        assert_eq!(
            describe(describe_test_ufvk(&MAIN_NETWORK), crate::NETWORK_ID_MAINNET),
            every_component
        );
        assert_eq!(
            describe(describe_test_ufvk(&TEST_NETWORK), crate::NETWORK_ID_TESTNET),
            every_component
        );
    }

    /// A key with a single shielded item reports that item alone.
    #[test]
    fn describe_reports_orchard_only_and_sapling_only_keys() {
        let (orchard, sapling, _) = describe_test_items();

        assert_eq!(
            describe(ufvk_from_items(vec![orchard]), crate::NETWORK_ID_MAINNET),
            UfvkComponentFlags::ORCHARD.bits()
        );
        assert_eq!(
            describe(ufvk_from_items(vec![sapling]), crate::NETWORK_ID_MAINNET),
            UfvkComponentFlags::SAPLING.bits()
        );
    }

    /// A P2SH viewing-key item is reported as P2SH, never as P2PKH.
    #[test]
    fn describe_reports_a_p2sh_key_apart_from_p2pkh() {
        assert_eq!(
            describe(P2SH_ORCHARD_UFVK_VECTOR, crate::NETWORK_ID_MAINNET),
            (UfvkComponentFlags::P2SH | UfvkComponentFlags::ORCHARD).bits()
        );
    }

    /// A data item of a typecode this library does not recognize sets the unknown flag, next to
    /// the flags of the items it does recognize.
    #[test]
    fn describe_reports_unknown_items() {
        let (orchard, sapling, p2pkh) = describe_test_items();
        let unknown = unified::Fvk::Unknown {
            typecode: 0xff00,
            data: vec![1, 2, 3, 4],
        };

        assert_eq!(
            describe(
                ufvk_from_items(vec![orchard, sapling, p2pkh, unknown]),
                crate::NETWORK_ID_MAINNET
            ),
            (UfvkComponentFlags::P2PKH
                | UfvkComponentFlags::SAPLING
                | UfvkComponentFlags::ORCHARD
                | UfvkComponentFlags::UNKNOWN)
                .bits()
        );
    }

    /// A key for one network is not a UFVK for the other.
    #[test]
    fn describe_returns_minus_one_for_wrong_network() {
        assert_not_a_ufvk(
            describe_test_ufvk(&MAIN_NETWORK),
            crate::NETWORK_ID_TESTNET,
            "a mainnet key on testnet",
        );
        assert_not_a_ufvk(
            describe_test_ufvk(&TEST_NETWORK),
            crate::NETWORK_ID_MAINNET,
            "a testnet key on mainnet",
        );
    }

    /// An incoming viewing key, strings that are no key at all, and a key with one character
    /// changed are not UFVKs.
    #[test]
    fn describe_returns_minus_one_for_uivk_garbage_and_bad_checksum() {
        let uivk = describe_test_key(&MAIN_NETWORK)
            .to_unified_incoming_viewing_key()
            .encode(&MAIN_NETWORK)
            .expect("the UIVK encodes");
        let mut bad_checksum = describe_test_ufvk(&MAIN_NETWORK);
        let last = bad_checksum.pop().expect("the UFVK is not empty");
        bad_checksum.push(if last == 'q' { 'p' } else { 'q' });

        for (input, case) in [
            (uivk, "a UIVK"),
            ("garbage".to_string(), "garbage"),
            (String::new(), "an empty string"),
            (bad_checksum, "a UFVK with one character changed"),
        ] {
            assert_not_a_ufvk(input, crate::NETWORK_ID_MAINNET, case);
        }
    }

    /// Whitespace around a key does not change its description.
    #[test]
    fn describe_ignores_surrounding_whitespace() {
        let ufvk = describe_test_ufvk(&MAIN_NETWORK);
        let unpadded = describe(ufvk.as_str(), crate::NETWORK_ID_MAINNET);
        assert_eq!(
            unpadded,
            (UfvkComponentFlags::P2PKH | UfvkComponentFlags::SAPLING | UfvkComponentFlags::ORCHARD)
                .bits(),
            "the unpadded key must describe as a UFVK"
        );

        assert_eq!(
            describe(format!("  \n{ufvk}\t"), crate::NETWORK_ID_MAINNET),
            unpadded
        );
    }

    /// The last error of an internal failure holds no part of the key the call was given: no
    /// 16-character window of the key appears in it.
    #[test]
    fn describe_errors_never_contain_the_input() {
        let ufvk = describe_test_ufvk(&MAIN_NETWORK);
        let mut not_utf8 = ufvk.clone().into_bytes();
        not_utf8.push(0xff);

        for (input, network_id, case) in [
            (ufvk.clone().into_bytes(), 99, "an invalid network id"),
            (
                not_utf8,
                crate::NETWORK_ID_MAINNET,
                "input that is not UTF-8",
            ),
        ] {
            assert_eq!(describe(input, network_id), -2, "{case}");
            assert_no_echo(&last_error_message(), &ufvk, case);
        }
    }

    /// A null pointer is an internal failure: `-2`, with a last error set.
    #[test]
    fn describe_returns_minus_two_for_a_null_pointer() {
        crate::zcashlc_clear_last_error();
        let result = unsafe {
            zcashlc_describe_unified_full_viewing_key(std::ptr::null(), crate::NETWORK_ID_MAINNET)
        };

        assert_eq!(result, -2);
        assert!(
            crate::zcashlc_last_error_length() > 0,
            "a null pointer must set a last error"
        );
    }

    /// A value that does not decode as a UFVK leaves a last error that holds no part of it,
    /// whether it is no key at all or a real key for the other network: the text reaches app
    /// logs, and a viewing key is a secret. The error is one fixed sentence, so it cannot carry
    /// what the decoder reports about the value either.
    #[test]
    fn derive_address_from_ufvk_error_omits_the_input() {
        const EXPECTED: &str = "The value did not decode as a valid UFVK";
        let testnet_ufvk = describe_test_ufvk(&TEST_NETWORK);
        for (input, case) in [
            (
                format!("uview1notakey{}", "padding".repeat(8)),
                "a string that is no key",
            ),
            (testnet_ufvk, "a key for the other network"),
        ] {
            let ufvk = CString::new(input.as_str()).expect("the input has no interior NUL");
            crate::zcashlc_clear_last_error();
            let address = unsafe {
                zcashlc_derive_address_from_ufvk(
                    crate::NETWORK_ID_MAINNET,
                    ufvk.as_ptr(),
                    std::ptr::null(),
                )
            };

            assert!(address.is_null(), "{case} must not derive an address");
            let message = last_error_message();
            assert_no_echo(&message, &input, case);
            assert_eq!(message, EXPECTED, "{case}");
        }
    }

    /// The same for a UIVK.
    #[test]
    fn derive_address_from_uivk_error_omits_the_input() {
        const EXPECTED: &str = "The value did not decode as a valid UIVK";
        let testnet_uivk = describe_test_key(&TEST_NETWORK)
            .to_unified_incoming_viewing_key()
            .encode(&TEST_NETWORK)
            .expect("the UIVK encodes");
        for (input, case) in [
            (
                format!("uivk1notakey{}", "padding".repeat(8)),
                "a string that is no key",
            ),
            (testnet_uivk, "a key for the other network"),
        ] {
            let uivk = CString::new(input.as_str()).expect("the input has no interior NUL");
            crate::zcashlc_clear_last_error();
            let address = unsafe {
                zcashlc_derive_address_from_uivk(
                    crate::NETWORK_ID_MAINNET,
                    uivk.as_ptr(),
                    std::ptr::null(),
                )
            };

            assert!(address.is_null(), "{case} must not derive an address");
            let message = last_error_message();
            assert_no_echo(&message, &input, case);
            assert_eq!(message, EXPECTED, "{case}");
        }
    }
}
