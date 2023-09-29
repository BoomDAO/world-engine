import A "mo:base/AssocList";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Bool "mo:base/Bool";
import Buffer "mo:base/Buffer";
import Cycles "mo:base/ExperimentalCycles";
import Char "mo:base/Char";
import Error "mo:base/Error";
import Float "mo:base/Float";
import HashMap "mo:base/HashMap";
import Hash "mo:base/Hash";
import Map "mo:base/HashMap";
import Int "mo:base/Int";
import Int16 "mo:base/Int16";
import Int8 "mo:base/Int8";
import Iter "mo:base/Iter";
import L "mo:base/List";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prelude "mo:base/Prelude";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Trie2D "mo:base/Trie";

import UserNode "./UserNode";
import JSON "../utils/Json";
import Parser "../utils/Parser";
import ENV "../utils/Env";
import Utils "../utils/Utils";
import AccountIdentifier "../utils/AccountIdentifier";
import Hex "../utils/Hex";
import EXTCORE "../utils/Core";
import EXT "../types/ext.types";
import Management "../modules/Management";

import EntityTypes "../types/entity.types";
import TGlobal "../types/global.types";

actor WorldHub {
    //stable memory
    private stable var _uids : Trie.Trie<TGlobal.userId, TGlobal.nodeId> = Trie.empty(); //mapping user_id -> node_canister_id
    private stable var _usernames : Trie.Trie<Text, TGlobal.userId> = Trie.empty(); //mapping username -> _uid
    private stable var _nodes : [TGlobal.nodeId] = []; //all user db canisters as nodes
    private stable var _admins : [Text] = []; //admins for user db
    private stable var _permissions : Trie.Trie<Text, Trie.Trie<Text, EntityTypes.EntityPermission>> = Trie.empty(); // [key1 = "worldCanisterId + "+" + GroupId + "+" + EntityId"] [key2 = Principal permitted] [Value = Entity Details]
    private stable var _globalPermissions : Trie.Trie<TGlobal.worldId, [TGlobal.userId]> = Trie.empty(); // worldId -> Principal permitted to change all entities of world
    private func WorldHubCanisterId() : Principal = Principal.fromActor(WorldHub);

    //Internals Functions
    private func countUsers_(nid : Text) : (Nat32) {
        var count : Nat32 = 0;
        for ((uid, canister) in Trie.iter(_uids)) {
            if (canister == nid) {
                count := count + 1;
            };
        };
        return count;
    };

    private func addText_(arr : [Text], id : Text) : ([Text]) {
        var b : Buffer.Buffer<Text> = Buffer.Buffer<Text>(0);
        for (i in arr.vals()) {
            b.add(i);
        };
        b.add(id);
        return Buffer.toArray(b);
    };

    private func updateCanister_(a : actor {}) : async () {
        let cid = { canister_id = Principal.fromActor(a) };
        let IC : Management.Management = actor (ENV.IC_Management);
        await (
            IC.update_settings({
                canister_id = cid.canister_id;
                settings = {
                    controllers = ?[WorldHubCanisterId()];
                    compute_allocation = null;
                    memory_allocation = null;
                    freezing_threshold = ?31_540_000;
                };
            })
        );
    };

    private func createCanister_() : async (Text) {
        Cycles.add(2000000000000);
        let canister = await UserNode.UserNode();
        let _ = await updateCanister_(canister); // update canister permissions and settings
        let canister_id = Principal.fromActor(canister);
        return Principal.toText(canister_id);
    };

    private func isAdmin_(_p : Principal) : (Bool) {
        var p : Text = Principal.toText(_p);
        for (i in _admins.vals()) {
            if (p == i) {
                return true;
            };
        };
        return false;
    };

    private func updateGlobalPermissions_(canister_id : Text) : async () {
        for ((_key, _permission) in Trie.iter(_permissions)) {
            let node = actor (canister_id) : actor {
                synchronizeEntityPermissions : shared (Text, Trie.Trie<Text, EntityTypes.EntityPermission>) -> async ();
                synchronizeGlobalPermissions : shared (Trie.Trie<TGlobal.worldId, [TGlobal.worldId]>) -> async ();
            };
            await node.synchronizeEntityPermissions(_key, _permission);
        };
        let node = actor (canister_id) : actor {
            synchronizeGlobalPermissions : shared (Trie.Trie<TGlobal.worldId, [TGlobal.worldId]>) -> async ();
        };
        await node.synchronizeGlobalPermissions(_globalPermissions);
    };

    //Queries
    //
    public query func cycleBalance() : async Nat {
        Cycles.balance();
    };

    public query func totalUsers() : async (Nat) {
        return Trie.size(_uids);
    };

    public query func getUserNodeCanisterId(_uid : Text) : async (Result.Result<Text, Text>) {
        switch (Trie.find(_uids, Utils.keyT(_uid), Text.equal)) {
            case (?c) {
                return #ok(c);
            };
            case _ {
                return #err("user not found");
            };
        };
    };

    public query func getAllNodeIds() : async [Text] {
        return _nodes;
    };

    public query func getAllAdmins() : async [Text] {
        return _admins;
    };

    public query func checkUsernameAvailability(_u : Text) : async (Bool) {
        switch (Trie.find(_usernames, Utils.keyT(_u), Text.equal)) {
            case (?t) {
                return false;
            };
            case _ {
                return true;
            };
        };
    };

    public query func getTokenIdentifier(t : Text, i : EXT.TokenIndex) : async (EXT.TokenIdentifier) {
        return EXTCORE.TokenIdentifier.fromText(t, i);
    };

    public query func getAccountIdentifier(p : Text) : async AccountIdentifier.AccountIdentifier {
        return AccountIdentifier.fromText(p, null);
    };

    //Updates
    public shared ({ caller }) func addAdmin(p : Text) : async () {
        assert (isAdmin_(caller));
        var b : Buffer.Buffer<Text> = Buffer.fromArray(_admins);
        b.add(p);
        _admins := Buffer.toArray(b);
    };

    public shared ({ caller }) func removeAdmin(p : Text) : async () {
        assert (isAdmin_(caller));
        var b : Buffer.Buffer<Text> = Buffer.Buffer<Text>(0);
        for (i in _admins.vals()) {
            if (i != p) {
                b.add(i);
            };
        };
        _admins := Buffer.toArray(b);
    };

    public shared ({ caller }) func createNewUser(user : Principal) : async (Result.Result<Text, Text>) {
        var _uid : Text = Principal.toText(user);
        switch (await getUserNodeCanisterId(_uid)) {
            case (#ok o) {
                return #err("user already exist");
            };
            case (#err e) {
                var canister_id : Text = "";
                label _check for (can_id in _nodes.vals()) {
                    var size : Nat32 = countUsers_(can_id);
                    if (size < 20) {
                        canister_id := can_id;
                        _uids := Trie.put(_uids, Utils.keyT(_uid), Text.equal, canister_id).0;
                        break _check;
                    };
                };
                if (canister_id == "") {
                    canister_id := await createCanister_();
                    _nodes := addText_(_nodes, canister_id);
                    _uids := Trie.put(_uids, Utils.keyT(_uid), Text.equal, canister_id).0;
                };
                let node = actor (canister_id) : actor {
                    adminCreateUser : shared (Text) -> async ();
                };
                await node.adminCreateUser(Principal.toText(user));
                await updateGlobalPermissions_(canister_id);
                return #ok(canister_id);
            };
        };
    };

    //admin endpoints
    //
    public shared ({ caller }) func admin_create_user(_uid : Text) : async (Result.Result<Text, Text>) {
        assert (isAdmin_(caller));
        switch (await getUserNodeCanisterId(_uid)) {
            case (#ok o) {
                return #err("user already exist");
            };
            case (#err e) {
                var canister_id : Text = "";
                label _check for (can_id in _nodes.vals()) {
                    var size : Nat32 = countUsers_(can_id);
                    if (size < 1000) {
                        canister_id := can_id;
                        _uids := Trie.put(_uids, Utils.keyT(_uid), Text.equal, canister_id).0;
                        break _check;
                    };
                };
                if (canister_id == "") {
                    canister_id := await createCanister_();
                    _nodes := addText_(_nodes, canister_id);
                    _uids := Trie.put(_uids, Utils.keyT(_uid), Text.equal, canister_id).0;
                };
                let node = actor (canister_id) : actor {
                    adminCreateUser : shared (Text) -> async ();
                };
                await node.adminCreateUser(_uid);
                await updateGlobalPermissions_(canister_id);
                return #ok(canister_id);
            };
        };
    };

    public shared ({ caller }) func admin_delete_user(uid : Text) : async () {
        assert (isAdmin_(caller));
        _uids := Trie.remove(_uids, Utils.keyT(uid), Text.equal).0;
        return ();
    };

    public shared ({ caller }) func setUsername(_uid : Text, _name : Text) : async (Result.Result<Text, Text>) {
        if (_uid != Principal.toText(caller)) {
            return #err("caller not authorised");
        };
        switch (Trie.find(_usernames, Utils.keyT(_name), Text.equal)) {
            case (?u) {
                return #err("username already exist, try something else!");
            };
            case _ {
                for ((i, v) in Trie.iter(_usernames)) {
                    if (v == _uid) {
                        _usernames := Trie.remove(_usernames, Utils.keyT(i), Text.equal).0;
                    };
                };
                _usernames := Trie.put(_usernames, Utils.keyT(_name), Text.equal, _uid).0;
                return #ok("updated!");
            };
        };
    };

    //world Canister Permission Rules
    //
    public shared ({ caller }) func grantEntityPermission(permission : EntityTypes.EntityPermission) : async () {
        let callerWorldId = Principal.toText(caller);
        let k = callerWorldId # "+" #permission.gid # "+" #permission.eid;
        _permissions := Trie.put2D(_permissions, Utils.keyT(k), Text.equal, Utils.keyT(permission.wid), Text.equal, permission);
        for (i in _nodes.vals()) {
            let node = actor (i) : actor {
                grantEntityPermission : shared (Text, EntityTypes.EntityPermission) -> async ();
            };
            await node.grantEntityPermission(callerWorldId, permission);
        };
    };

    public shared ({ caller }) func removeEntityPermission(permission : EntityTypes.EntityPermission) : async () {
        let callerWorldId = Principal.toText(caller);
        let k = callerWorldId # "+" #permission.gid # "+" #permission.eid;
        switch (Trie.find(_permissions, Utils.keyT(k), Text.equal)) {
            case (?p) {
                _permissions := Trie.remove2D(_permissions, Utils.keyT(k), Text.equal, Utils.keyT(permission.wid), Text.equal).0;
            };
            case _ {};
        };
        for (i in _nodes.vals()) {
            let node = actor (i) : actor {
                removeEntityPermission : shared (Text, EntityTypes.EntityPermission) -> async ();
            };
            await node.removeEntityPermission(callerWorldId, permission);
        };
    };

    public shared ({ caller }) func grantGlobalPermission(permission : EntityTypes.GlobalPermission) : async () {
        switch (Trie.find(_globalPermissions, Utils.keyT(Principal.toText(caller)), Text.equal)) {
            case (?p) {
                var b : Buffer.Buffer<Text> = Buffer.fromArray(p);
                b.add(permission.wid);
                _globalPermissions := Trie.put(_globalPermissions, Utils.keyT(Principal.toText(caller)), Text.equal, Buffer.toArray(b)).0;
            };
            case _ {
                var b : Buffer.Buffer<Text> = Buffer.Buffer<Text>(0);
                b.add(permission.wid);
                _globalPermissions := Trie.put(_globalPermissions, Utils.keyT(Principal.toText(caller)), Text.equal, Buffer.toArray(b)).0;
            };
        };
        for (i in _nodes.vals()) {
            let node = actor (i) : actor {
                grantGlobalPermission : shared (Text, EntityTypes.GlobalPermission) -> async ();
            };
            await node.grantGlobalPermission(Principal.toText(caller), permission);
        };
    };

    public shared ({ caller }) func removeGlobalPermission(permission : EntityTypes.GlobalPermission) : async () {
        switch (Trie.find(_globalPermissions, Utils.keyT(Principal.toText(caller)), Text.equal)) {
            case (?p) {
                var b : Buffer.Buffer<Text> = Buffer.Buffer<Text>(0);
                for (i in p.vals()) {
                    if (i != permission.wid) {
                        b.add(i);
                    };
                };
                _globalPermissions := Trie.put(_globalPermissions, Utils.keyT(Principal.toText(caller)), Text.equal, Buffer.toArray(b)).0;
            };
            case _ {};
        };
        for (i in _nodes.vals()) {
            let node = actor (i) : actor {
                removeGlobalPermission : shared (Text, EntityTypes.GlobalPermission) -> async ();
            };
            await node.removeGlobalPermission(Principal.toText(caller), permission);
        };
    };

    public shared ({ caller }) func importAllUsersDataOfWorld(ofWorldId : Text) : async (Result.Result<Text, Text>) {
        let toWorldId : Text = Principal.toText(caller);
        var countOfNodesUpdated : Nat = 0;
        for (i in _nodes.vals()) {
            let node = actor (i) : actor {
                importAllUsersDataOfWorld : shared (Text, Text) -> async (Result.Result<Text, Text>);
            };
            var res = await node.importAllUsersDataOfWorld(ofWorldId, toWorldId);
            switch (res) {
                case (#ok _) countOfNodesUpdated := countOfNodesUpdated + 1;
                case _ {};
            };
        };
        if (countOfNodesUpdated == _nodes.size()) {
            return #ok("imported");
        } else {
            return #err("some error occured in userNodes, contact dev team in discord");
        };
    };

    public shared ({ caller }) func importAllPermissionsOfWorld(ofWorldId : Text) : async (Result.Result<Text, Text>) {
        let toWorldId : Text = Principal.toText(caller);
        for ((id, trie) in Trie.iter(_permissions)) {
            let ids = Iter.toArray(Text.tokens(id, #text("+"))); //"worldCanisterId + "+" + GroupId + "+" + EntityId"
            if (ids[0] == ofWorldId) {
                let new_id = toWorldId # "+" #ids[1] # "+" #ids[2];
                _permissions := Trie.put(_permissions, Utils.keyT(new_id), Text.equal, trie).0;
            };
        };
        switch (Trie.find(_globalPermissions, Utils.keyT(ofWorldId), Text.equal)) {
            case (?p) {
                _globalPermissions := Trie.put(_globalPermissions, Utils.keyT(toWorldId), Text.equal, p).0;
            };
            case _ {};
        };
        var countOfNodesUpdated : Nat = 0;
        for (i in _nodes.vals()) {
            let node = actor (i) : actor {
                importAllPermissionsOfWorld : shared (Text, Text) -> async (Result.Result<Text, Text>);
            };
            var res = await node.importAllPermissionsOfWorld(ofWorldId, toWorldId);
            switch (res) {
                case (#ok _) countOfNodesUpdated := countOfNodesUpdated + 1;
                case _ {};
            };
        };
        if (countOfNodesUpdated == _nodes.size()) {
            return #ok("imported");
        } else {
            return #err("some error occured in userNodes, contact dev team in discord");
        };
    };

    public shared ({ caller }) func getGlobalPermissionsOfWorld() : async ([TGlobal.worldId]) {
        let worldId = Principal.toText(caller);
        return Option.get(Trie.find(_globalPermissions, Utils.keyT(worldId), Text.equal), []);
    };

    public shared ({ caller }) func getEntityPermissionsOfWorld() : async [(Text, [(Text, EntityTypes.EntityPermission)])] {
        let worldId : Text = Principal.toText(caller);
        var b : Buffer.Buffer<(Text, [(Text, EntityTypes.EntityPermission)])> = Buffer.Buffer<(Text, [(Text, EntityTypes.EntityPermission)])>(0);
        var a = Buffer.Buffer<(Text, EntityTypes.EntityPermission)>(0);
        for ((id, trie) in Trie.iter(_permissions)) {
            let ids = Iter.toArray(Text.tokens(id, #text("+"))); //"worldCanisterId + "+" + GroupId + "+" + EntityId"
            if (worldId == ids[0]) {
                for ((allowed_user, entity_permission) in Trie.iter(trie)) {
                    a.add((allowed_user, entity_permission));
                };
                b.add((ids[2], Buffer.toArray(a)));
            };
        };
        Buffer.toArray(b);
    };

    // custom SNS functions for upgrading UserNodes which are under control of WorldHub canister
    public shared ({ caller }) func validate_upgrade_usernodes(usernode_wasm_module : Blob) : async ({
        #Ok : Text;
        #Err : Text;
    }) {
        // assert (caller == Principal.fromText(""));
        return #Ok("passed");
    };

    public shared ({ caller }) func upgrade_usernodes(usernode_wasm_module : Blob) : async () {
        // assert (caller == Principal.fromText(""));
        for (node in _nodes.vals()) {
            let IC : Management.Management = actor (ENV.IC_Management);
            await IC.install_code({
                arg = [];
                wasm_module = usernode_wasm_module;
                mode = #reinstall;
                canister_id = Principal.fromText(node);
                sender_canister_version = null;
            });
        };
    };

};
