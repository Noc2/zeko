import { GraphQLError } from "graphql";
import { FieldConst, MinaUtils, Signature } from "snarkyjs";
import { RollupContext } from ".";
import { MutationResolvers } from "../generated/graphql";

export const mutations: MutationResolvers = {
  async sendPayment(_, { input, signature }, { rollup }: RollupContext) {
    try {
      const { hash, id } = await rollup.applyPayment(
        Signature.fromJSON({
          r: signature?.field,
          s: signature?.scalar,
        }),
        input
      );

      const feePayer = rollup.getAccount(MinaUtils.encoding.publicKeyOfBase58(input.from), FieldConst[1]);

      const receiver = rollup.getAccount(MinaUtils.encoding.publicKeyOfBase58(input.from), FieldConst[1]);

      if (feePayer === null || receiver === null) {
        throw new Error("Unexpected error, account was not created");
      }

      return {
        payment: {
          __typename: "UserCommandPayment",
          amount: input.amount,
          failureReason: null,
          fee: input.fee,
          feePayer,
          feeToken: "1",
          from: input.from,
          fromAccount: feePayer,
          hash: hash,
          id,
          isDelegation: false,
          kind: "Payment",
          memo: input.memo ?? "",
          nonce: input.nonce,
          receiver,
          source: feePayer,
          to: input.to,
          toAccount: receiver,
          token: "1",
          validUntil: input.validUntil,
        },
      };
    } catch (e) {
      console.error(e);
      if (e instanceof Error) {
        throw new GraphQLError(e.message);
      }
      throw new GraphQLError("Unknown error");
    }
  },
};
